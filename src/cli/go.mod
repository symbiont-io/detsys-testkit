module github.com/symbiont-io/detsys-testkit/src/cli

go 1.15

replace github.com/symbiont-io/detsys-testkit/src/lib => ../lib

require (
	github.com/spf13/cobra v1.1.1
	github.com/symbiont-io/detsys-testkit/src/lib v0.0.0-00010101000000-000000000000
)
