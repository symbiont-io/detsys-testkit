package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"

	"github.com/symbiont-io/detsys-testkit/src/executor"
	"github.com/symbiont-io/detsys-testkit/src/lib"
	"github.com/symbiont-io/detsys-testkit/src/sut/register"
)

func constructor(name string) lib.Reactor {
	switch name {
	case "frontend":
		return sut.NewFrontEnd()
	case "register":
		return sut.NewRegister()
	default:
		panic(name)
	}
}

func main() {
	var srv http.Server

	idleConnsClosed := make(chan struct{})
	go func() {
		sigint := make(chan os.Signal, 1)
		signal.Notify(sigint, os.Interrupt)
		<-sigint

		// We received an interrupt signal, shut down.
		if err := srv.Shutdown(context.Background()); err != nil {
			// Error from closing listeners, or context timeout:
			log.Printf("HTTP server Shutdown: %v", err)
		}
		close(idleConnsClosed)
	}()

	// TODO(stevan): parse topology from file, db or cmd args...
	topology := map[string]string{
		"frontend":  "frontend",
		"register1": "register",
		"register2": "register",
	}
	marshaler := sut.NewMarshaler()
	log.Printf("Deploying topology: %v", topology)
	executor.DeployRaw(&srv, topology, marshaler, constructor)

	<-idleConnsClosed
}
