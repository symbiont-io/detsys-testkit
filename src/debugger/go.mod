module github.com/symbiont-io/detsys-testkit/src/debugger

go 1.15

replace github.com/symbiont-io/detsys-testkit/src/lib => ../lib

require (
	github.com/andreyvit/diff v0.0.0-20170406064948-c7f18ee00883
	github.com/evanphx/json-patch v4.9.0+incompatible
	github.com/gdamore/tcell/v2 v2.0.1-0.20201017141208-acf90d56d591
	github.com/mattn/go-sqlite3 v1.14.5
	github.com/nsf/jsondiff v0.0.0-20200515183724-f29ed568f4ce
	github.com/pkg/errors v0.8.1 // indirect
	github.com/rivo/tview v0.0.0-20201018122409-d551c850a743
	github.com/sergi/go-diff v1.1.0 // indirect
	github.com/symbiont-io/detsys-testkit/src/lib v0.0.0-00010101000000-000000000000
)
