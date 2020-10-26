package sut

import (
	"context"
	"log"
	"net/http"
	"testing"

	"github.com/symbiont-io/detsys/executor"
	"github.com/symbiont-io/detsys/lib"
)

func once(testId lib.TestId, t *testing.T) (lib.RunId, bool) {
	frontEnd := NewFrontEnd()
	topology := map[string]lib.Reactor{
		"frontend":  frontEnd,
		"register1": NewRegister(),
		"register2": NewRegister(),
	}
	var srv http.Server
	lib.Setup(func() {
		executor.Deploy(&srv, topology,
			frontEnd, // TODO(stevan): can we get rid of this?
			frontEnd)
	})
	qs := lib.LoadTest(testId)
	log.Printf("Loaded test of size: %d\n", qs.QueueSize)
	executor.Register(topology)
	runId := lib.CreateRun(testId)
	lib.Run()
	log.Printf("Finished run id: %d\n", runId.RunId)
	lib.Teardown()
	if err := srv.Shutdown(context.Background()); err != nil {
		panic(err)
	}
	result := lib.Check("list-append", testId, runId)
	return runId, result
}

func TestDummy(t *testing.T) {
	testId := lib.GenerateTest()

	var runIds []lib.RunId
	var faults []lib.Fault
	failSpec := lib.FailSpec{
		EFF:     10,
		Crashes: 0,
		EOT:     0,
	}
	for {
		lib.Reset()
		lib.InjectFaults(lib.Faults{faults})
		runId, result := once(testId, t)
		if !result {
			t.Errorf("Test-run %d doesn't pass analysis", runId)
			t.Errorf("faults: %#v\n", faults)
			break
		}
		runIds = append(runIds, runId)
		faults = lib.Ldfi(testId, runIds, failSpec).Faults
		if len(faults) == 0 {
			break
		}
	}

}
