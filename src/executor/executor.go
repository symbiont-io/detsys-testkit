package executor

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"github.com/symbiont-io/detsys-testkit/src/lib"
)

func jsonError(s string) string {
	return fmt.Sprintf("{\"error\":\"%s\"}", s)
}

type ComponentUpdate = func(component string, at time.Time)
type Topology = map[string]lib.Reactor

func handler(db *sql.DB, testId lib.TestId, eventLog lib.EventLogEmitter, topology Topology, m lib.Marshaler, cu ComponentUpdate) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		eventLog.Emit("handleReceive", "Start")
		defer eventLog.Emit("handleReceive", "End")
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
		cu(sev.To, sev.At)
		// TODO(danne) these should also be events
		heapBefore := dumpHeapJson(topology[sev.To])
		oevs := topology[sev.To].Receive(sev.At, sev.From, sev.Event)
		heapAfter := dumpHeapJson(topology[sev.To])
		heapDiff := jsonDiff(heapBefore, heapAfter)
		appendHeapTrace(db, testId, sev.To, heapDiff, sev.At)
		bs := lib.MarshalUnscheduledEvents(sev.To, oevs)
		fmt.Fprint(w, string(bs))
	}
}

func handleTick(eventLog lib.EventLogEmitter, topology Topology, m lib.Marshaler, cu ComponentUpdate) http.HandlerFunc {
	type TickRequest struct {
		Component string    `json:"component"`
		At        time.Time `json:"at"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		eventLog.Emit("handleTick", "Start")
		defer eventLog.Emit("handleTick", "End")
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
		cu(req.Component, req.At)
		oevs := topology[req.Component].Tick(req.At)
		bs := lib.MarshalUnscheduledEvents(req.Component, oevs)
		fmt.Fprint(w, string(bs))
	}
}

func handleTimer(db *sql.DB, testId lib.TestId, eventLog lib.EventLogEmitter, topology Topology, m lib.Marshaler, cu ComponentUpdate) http.HandlerFunc {
	type TimerRequest struct {
		Component string    `json:"to"`
		At        time.Time `json:"at"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		eventLog.Emit("handleTimer", "Start")
		defer eventLog.Emit("handleTimer", "End")
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
		cu(req.Component, req.At)
		heapBefore := dumpHeapJson(topology[req.Component])
		oevs := topology[req.Component].Timer(req.At)
		heapAfter := dumpHeapJson(topology[req.Component])
		heapDiff := jsonDiff(heapBefore, heapAfter)

		appendHeapTrace(db, testId, req.Component, heapDiff, req.At)
		bs := lib.MarshalUnscheduledEvents(req.Component, oevs)
		fmt.Fprint(w, string(bs))
	}
}

func handleInits(topology Topology, m lib.Marshaler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if r.Method != "GET" {
			http.Error(w, jsonError("Method is not supported."),
				http.StatusNotFound)
			return
		}

		var inits []lib.Event
		for component, reactor := range topology {
			inits = append(inits,
				lib.OutEventsToEvents(component, reactor.Init())...)
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

func Register(eventLog lib.EventLogEmitter, topology Topology) {
	eventLog.Emit("Register Executor", "Start")
	defer eventLog.Emit("Register Executor", "End")
	// TODO(stevan): Make executorUrl part of topology/deployment.
	const executorUrl string = "http://localhost:3001/api/v1/"

	components, err := componentsFromDeployment(testId)
	if err != nil {
		panic(err)
	}

	lib.RegisterExecutor(executorUrl, components)
}

func DeployWithComponentUpdate(srv *http.Server, testId lib.TestId, eventLog lib.EventLogEmitter, topology Topology, m lib.Marshaler, cu ComponentUpdate) {
	eventLog.Emit("Deploy Executor", "Start")
	defer eventLog.Emit("Deploy Executor", "End")
	mux := http.NewServeMux()

	db := lib.OpenDB()
	defer db.Close()

	mux.HandleFunc("/api/v1/event", handler(db, testId, eventLog, topology, m, cu))
	mux.HandleFunc("/api/v1/tick", handleTick(eventLog, topology, m, cu))
	mux.HandleFunc("/api/v1/timer", handleTimer(db, testId, eventLog, topology, m, cu))
	mux.HandleFunc("/api/v1/inits", handleInits(topology, m))

	srv.Addr = ":3001"
	srv.Handler = mux
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		panic(err)
	}
}

func Deploy(srv *http.Server, testId lib.TestId, eventLog lib.EventLogEmitter, topology Topology, m lib.Marshaler) {
	DeployWithComponentUpdate(srv, testId, eventLog, topology, m, func(string, time.Time) {})
}

func topologyFromDeployment(testId lib.TestId, constructor func(string) lib.Reactor) (Topology, error) {
	query := fmt.Sprintf(`SELECT component,type
                              FROM deployment
                              WHERE test_id = %d`, testId.TestId)

	db := lib.OpenDB()
	defer db.Close()

	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	topologyRaw := make(map[string]string)
	type Column struct {
		Component string
		Type      string
	}
	for rows.Next() {
		column := Column{}
		err := rows.Scan(&column.Component, &column.Type)
		if err != nil {
			return nil, err
		}
		topologyRaw[column.Component] = column.Type
	}

	topologyCooked := make(Topology)
	for component, typ := range topologyRaw {
		topologyCooked[component] = constructor(typ)
	}
	return topologyCooked, nil
}

func DeployRaw(srv *http.Server, testId lib.TestId, eventLog lib.EventLogEmitter, topology map[string]string, m lib.Marshaler, constructor func(string) lib.Reactor) {
	topologyCooked, err := topologyFromDeployment(testId, constructor)
	if err != nil {
		panic(err)
	}
	fmt.Printf("Deploying topology: %+v\n", topologyCooked)
	Deploy(srv, testId, eventLog, topologyCooked, m)
}

func componentsFromDeployment(testId lib.TestId) ([]string, error) {
	query := fmt.Sprintf(`SELECT component
                              FROM deployment
                              WHERE test_id = %d`, testId.TestId)

	db := lib.OpenDB()
	defer db.Close()

	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var components []string
	type Column struct {
		Component string
	}
	for rows.Next() {
		column := Column{}
		err := rows.Scan(&column.Component)
		if err != nil {
			return nil, err
		}
		components = append(components, column.Component)
	}
	return components, nil
}

type LogWriter struct {
	testId    lib.TestId
	runId     lib.RunId
	component string
	at        time.Time
}

func (_ *LogWriter) Sync() error {
	return nil
}

func (lw *LogWriter) Write(p []byte) (n int, err error) {
	if len(p) > 0 {
		// we remove last byte since it is an newline
		lib.AddLogStamp(lw.testId, lw.runId, lw.component, p[:len(p)-1], lw.at)
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
	topology    Topology
	buffers     map[string]*LogWriter
	marshaler   lib.Marshaler
	testId      lib.TestId
	runId       lib.RunId
	constructor func(name string, logger *zap.Logger) lib.Reactor
	eventLog    lib.EventLogEmitter
	logger      *zap.Logger
}

func (e *Executor) ReactorTopology() Topology {
	return e.topology
}

func (e *Executor) SetTestId(testId lib.TestId) {
	e.testId = testId
	for _, buffer := range e.buffers {
		buffer.testId = testId
	}
}

func NewExecutor(testId lib.TestId, marshaler lib.Marshaler, logger *zap.Logger, components []string, constructor func(name string, logger *zap.Logger) lib.Reactor) *Executor {
	runId := lib.RunId{0}

	topology := make(map[string]lib.Reactor)
	buffers := make(map[string]*LogWriter)

	for _, component := range components {
		buffer := &LogWriter{
			testId:    testId,
			runId:     runId,
			component: component,
			at:        time.Time{},
		}
		topology[component] = constructor(component, buffer.AppendToLogger(logger))
		buffers[component] = buffer
	}

	executor := &Executor{
		topology:    topology,
		buffers:     buffers,
		marshaler:   marshaler,
		testId:      testId,
		runId:       runId,
		constructor: constructor,
		eventLog: lib.EventLogEmitter{
			Component: "Executor",
			TestId:    nil,
			RunId:     nil,
		},
		logger: logger,
	}

	executor.eventLog.TestId = &executor.testId
	executor.eventLog.RunId = &executor.runId

	return executor
}

func (e *Executor) Deploy(srv *http.Server) {
	DeployWithComponentUpdate(srv, e.testId, e.eventLog, e.topology, e.marshaler, func(name string, at time.Time) {
		buffer, ok := e.buffers[name]

		if ok {
			buffer.at = at
		} else {
			panic(fmt.Sprintf("Couldn't find buffer for %s", name))
		}
	})
}

func (e *Executor) Register() {
	Register(e.eventLog, e.topology)
}

func (e *Executor) Reset(runId lib.RunId) {
	e.runId = runId
	for c, b := range e.buffers {
		b.runId = runId
		b.at = time.Time{}
		e.topology[c] = e.constructor(c, b.AppendToLogger(e.logger))
	}
}
