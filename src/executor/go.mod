module github.com/symbiont-io/detsys-testkit/src/executor

go 1.15

replace github.com/symbiont-io/detsys-testkit/src/lib => ../lib

require (
	github.com/evanphx/json-patch v4.9.0+incompatible
	github.com/symbiont-io/detsys-testkit/src/lib v0.0.0-00010101000000-000000000000
	go.uber.org/zap v1.20.0
)
