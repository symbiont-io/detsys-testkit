package executor

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"strconv"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"github.com/symbiont-io/detsys-testkit/src/lib"
)

func jsonError(s string) string {
	return fmt.Sprintf("{\"error\":\"%s\"}", s)
}

type StepInfo struct {
	LogLines []string
}

type ComponentUpdate = func(component string) StepInfo

func handler(db *sql.DB, topology lib.Topology, m lib.Marshaler, cu ComponentUpdate) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if r.Method != "POST" {
			http.Error(w, jsonError("Method is not supported."),
				http.StatusNotFound)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1048576)
		// XXX: Inefficient, reuse ideas from:
		// https://www.alexedwards.net/blog/how-to-properly-parse-a-json-request-body ?
		body, err := ioutil.ReadAll(r.Body)
		if err != nil {
			panic(err)
		}
		var sev lib.ScheduledEvent
		if err := lib.UnmarshalScheduledEvent(m, body, &sev); err != nil {
			panic(err)
		}
		reactor := topology.Reactor(sev.To)
		heapBefore := dumpHeapJson(reactor)
		oevs := reactor.Receive(sev.At, sev.From, sev.Event)
		heapAfter := dumpHeapJson(reactor)
		heapDiff := jsonDiff(heapBefore, heapAfter)
		si := cu(sev.To)

		EmitExecutionStepEvent(db, ExecutionStepEvent{
			Meta:          sev.Meta,
			Reactor:       sev.To,
			SimulatedTime: sev.At,
			LogLines:      si.LogLines,
			HeapDiff:      heapDiff,
		})
		corrId, err := strconv.Atoi(r.Header.Get("correlation-id"))
		if err != nil {
			corrId = -1
		}
		bs := lib.MarshalUnscheduledEvents(sev.To, corrId, oevs)
		fmt.Fprint(w, string(bs))
	}
}

func handleTick(topology lib.Topology, m lib.Marshaler, cu ComponentUpdate) http.HandlerFunc {
	type TickRequest struct {
		Reactor string    `json:"reactor"`
		At      time.Time `json:"at"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if r.Method != "PUT" {
			http.Error(w, jsonError("Method is not supported."),
				http.StatusNotFound)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1048576)
		body, err := ioutil.ReadAll(r.Body)
		if err != nil {
			panic(err)
		}
		var req TickRequest
		if err := json.Unmarshal(body, &req); err != nil {
			panic(err)
		}
		oevs := topology.Reactor(req.Reactor).Tick(req.At)
		cu(req.Reactor)
		// XXX: CorrId doesn't make sense here, right? Hence -1...
		bs := lib.MarshalUnscheduledEvents(req.Reactor, -1, oevs)
		fmt.Fprint(w, string(bs))
	}
}

func handleTimer(db *sql.DB, topology lib.Topology, m lib.Marshaler, cu ComponentUpdate) http.HandlerFunc {
	type TimerRequest struct {
		Reactor string       `json:"to"`
		At      time.Time    `json:"at"`
		Meta    lib.MetaInfo `json:"meta"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if r.Method != "POST" {
			http.Error(w, jsonError("Method is not supported."),
				http.StatusNotFound)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1048576)
		body, err := ioutil.ReadAll(r.Body)
		if err != nil {
			panic(err)
		}
		var req TimerRequest
		if err := json.Unmarshal(body, &req); err != nil {
			panic(err)
		}

		reactor := topology.Reactor(req.Reactor)
		heapBefore := dumpHeapJson(reactor)
		oevs := reactor.Timer(req.At)
		heapAfter := dumpHeapJson(reactor)
		heapDiff := jsonDiff(heapBefore, heapAfter)
		si := cu(req.Reactor)

		EmitExecutionStepEvent(db, ExecutionStepEvent{
			Meta:          req.Meta,
			Reactor:       req.Reactor,
			SimulatedTime: req.At,
			LogLines:      si.LogLines,
			HeapDiff:      heapDiff,
		})
		corrId, err := strconv.Atoi(r.Header.Get("correlation-id"))
		if err != nil {
			corrId = -1
		}
		bs := lib.MarshalUnscheduledEvents(req.Reactor, corrId, oevs)
		fmt.Fprint(w, string(bs))
	}
}

func handleInits(topology lib.Topology, m lib.Marshaler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if r.Method != "GET" {
			http.Error(w, jsonError("Method is not supported."),
				http.StatusNotFound)
			return
		}

		var inits []lib.Event

		reactors := topology.Reactors()
		for _, reactor := range reactors {
			inits = append(inits,
				lib.OutEventsToEvents(reactor, topology.Reactor(reactor).Init())...)
		}

		// Use `[]` for no events, rather than `null`, in the JSON encoding.
		if inits == nil {
			inits = []lib.Event{}
		}

		bs, err := json.Marshal(struct {
			Events []lib.Event `json:"events"`
		}{inits})
		if err != nil {
			panic(err)
		}

		fmt.Fprint(w, string(bs))
	}
}

func DeployWithComponentUpdate(srv *http.Server, topology lib.Topology, m lib.Marshaler, cu ComponentUpdate) {
	mux := http.NewServeMux()

	db := lib.OpenDB()
	defer db.Close()

	mux.HandleFunc("/api/v1/event", handler(db, topology, m, cu))
	mux.HandleFunc("/api/v1/tick", handleTick(topology, m, cu))
	mux.HandleFunc("/api/v1/timer", handleTimer(db, topology, m, cu))
	mux.HandleFunc("/api/v1/inits", handleInits(topology, m))

	srv.Addr = ":3001"
	srv.Handler = mux
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		panic(err)
	}
}

func Deploy(srv *http.Server, topology lib.Topology, m lib.Marshaler) {
	DeployWithComponentUpdate(srv, topology, m, func(string) StepInfo { return StepInfo{} })
}

func topologyFromDeployment(testId lib.TestId, constructor func(string) lib.Reactor) (lib.Topology, error) {
	topologyCooked := lib.NewTopology()
	deployments, err := lib.DeploymentInfoForTest(testId)

	if err != nil {
		return topologyCooked, err
	}
	for _, deploy := range deployments {
		topologyCooked.Insert(deploy.Reactor, constructor(deploy.Type))
	}
	return topologyCooked, nil
}

func DeployRaw(srv *http.Server, testId lib.TestId, m lib.Marshaler, constructor func(string) lib.Reactor) {
	topology, err := topologyFromDeployment(testId, constructor)
	if err != nil {
		panic(err)
	}
	fmt.Printf("Deploying topology: %+v\n", topology)
	Deploy(srv, topology, m)
}

type LogWriter struct {
	current [][]byte
}

func (_ *LogWriter) Sync() error {
	return nil
}

func (lw *LogWriter) Write(p []byte) (n int, err error) {
	if len(p) > 0 {
		// make a copy of the line so that it doesn't get changed later
		line := make([]byte, len(p))
		copy(line, p)

		// we remove last byte since it is an newline
		lw.current = append(lw.current, line[:len(line)-1])
	}
	return len(p), nil
}

func (lw *LogWriter) AppendToLogger(logger *zap.Logger) *zap.Logger {
	return logger.WithOptions(zap.WrapCore(func(c zapcore.Core) zapcore.Core {
		config := zap.NewDevelopmentEncoderConfig()
		config.TimeKey = ""
		config.LineEnding = ""
		dbLogger := zapcore.NewCore(zapcore.NewConsoleEncoder(config), lw, c)
		return zapcore.NewTee(c, dbLogger)
	}))
}

type Executor struct {
	topology    lib.Topology
	buffers     map[string]*LogWriter // we need to be careful with this one
	marshaler   lib.Marshaler
	testId      lib.TestId
	constructor func(name string, logger *zap.Logger) lib.Reactor
	logger      *zap.Logger
}

func (e *Executor) ReactorTopology() lib.Topology {
	return e.topology
}

func (e *Executor) SetTestId(testId lib.TestId) {
	e.testId = testId
}

func NewExecutor(marshaler lib.Marshaler, logger *zap.Logger, reactorNames []string, constructor func(name string, logger *zap.Logger) lib.Reactor) *Executor {
	topology := lib.NewTopology()
	buffers := make(map[string]*LogWriter)

	for _, reactorName := range reactorNames {
		buffer := &LogWriter{
			current: [][]byte{},
		}
		topology.Insert(reactorName, constructor(reactorName, buffer.AppendToLogger(logger)))
		buffers[reactorName] = buffer
	}

	return &Executor{
		topology:    topology,
		buffers:     buffers,
		marshaler:   marshaler,
		constructor: constructor,
		logger:      logger,
	}
}

func (e *Executor) Deploy(srv *http.Server) {
	DeployWithComponentUpdate(srv, e.topology, e.marshaler, func(name string) StepInfo {
		buffer, ok := e.buffers[name]
		if ok {
			logs := make([]string, 0, len(buffer.current))
			for _, l := range buffer.current {
				logs = append(logs, string(l))
			}
			buffer.current = make([][]byte, 0)
			return StepInfo{
				LogLines: logs,
			}
		}

		panic(fmt.Sprintf("Couldn't find buffer for %s", name))
	})
}

func (e *Executor) Register() {
	reactors := e.topology.Reactors()
	lib.RegisterExecutor("http://localhost:3001/api/v1/", reactors)
}

func (e *Executor) Reset() {
	for c, b := range e.buffers {
		e.topology.Insert(c, e.constructor(c, b.AppendToLogger(e.logger)))
	}
}
