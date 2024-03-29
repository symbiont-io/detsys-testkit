package debugger

import (
	"strings"
	"testing"

	"github.com/andreyvit/diff"
)

func goldenTest(t *testing.T, settings DrawSettings, arrows []Arrow, outcome string) {
	shouldBe := strings.TrimSpace(outcome)
	header, boxes, _ := DrawDiagram(arrows, settings)

	whole := strings.Join([]string{string(header), string(boxes)}, "\n")

	//sanitize, boxes might have some extra spaces at the end..
	boxesLines := strings.Split(whole, "\n")
	for i, s := range boxesLines {
		boxesLines[i] = strings.TrimRight(s, " ")
	}
	computed := strings.Join(boxesLines, "\n")

	if computed != shouldBe {
		t.Errorf("Diagram is not matching (+ is what it should be, - what was computed):\n%v", diff.LineDiff(shouldBe, computed))
	}
}

var arrows_1 = []Arrow{
	Arrow{
		From:    "Client",
		To:      "Frontend",
		Message: "start",
	},
	Arrow{
		From:    "Frontend",
		To:      "Register 1",
		Message: "hello",
	},
	Arrow{
		From:    "Register 2",
		To:      "Frontend",
		Message: "long ping?",
		Dropped: true,
	},
	Arrow{
		From:    "Frontend",
		To:      "Frontend",
		Message: "loop",
	},
	Arrow{
		From:    "Client",
		To:      "Register 2",
		Message: "This is a long message",
	},
	Arrow{
		From:    "Register 2",
		To:      "Register 2",
		Message: "end-loop",
	},
}

const outcome_1 = `
╭─────────────╮              ╭─────────────╮╭─────────────╮  ╭─────────────╮
│   Client    │              │  Frontend   ││ Register 1  │  │ Register 2  │
╰──────┬──────╯              ╰──────┬──────╯╰──────┬──────╯  ╰──────┬──────╯
       │           start            │              │                │
       ├────────────────────────────▶              │                │
       │                            │ ["focused"][yellow]>>>hello<<<[-][""]  │                │
       │                            ├──────────────▶                │
       │                            │              │   long ping?   │
       │                            ◀╌╌╌╌╌╌╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
       │                            │     loop     │                │
       │                            ├──────╮       │                │
       │                            ◀──────╯       │                │
       │   This is a long message   │              │                │
       ├────────────────────────────┼──────────────┼────────────────▶
       │                            │              │    end-loop    │
       │                            │              │         ╭──────┤
       │                            │              │         ╰──────▶
╭──────┴──────╮              ╭──────┴──────╮╭──────┴──────╮  ╭──────┴──────╮
│   Client    │              │  Frontend   ││ Register 1  │  │ Register 2  │
╰─────────────╯              ╰─────────────╯╰─────────────╯  ╰─────────────╯
`

var settings_1 = DrawSettings{
	MarkerSize: 3,
	MarkAt:     1,
}

var arrows_2 = []Arrow{
	Arrow{
		From:    "A",
		To:      "B",
		Message: "first",
		At:      0,
	},
	Arrow{
		From:    "B",
		To:      "C",
		Message: "second",
		Dropped: true,
		At:      1,
	},
}

const outcome_2 = `
╭───╮       ╭───╮        ╭───╮
│ A │       │ B │        │ C │
╰─┬─╯       ╰─┬─╯        ╰─┬─╯
  │   first   │            │
  ├───────────▶            │
[red]╭─┴─╮[-]         │          [red]╭─┴─╮[-]
[red]│ ☠ │[-]         │          [red]│ ☠ │[-]
[red]╰───╯[-]         │          [red]╰───╯[-]
              │["focused"][yellow]>>>second<<<[-][""]
              ├╌╌╌╌╌╌╌╌╌╌╌╌▶
╭─┴─╮       ╭─┴─╮        ╭─┴─╮
│ A │       │ B │        │ C │
╰───╯       ╰───╯        ╰───╯
`

var settings_2 = DrawSettings{
	MarkerSize: 3,
	MarkAt:     1,
	Crashes: map[int][]string{
		1: []string{"A", "C"},
	},
}

func TestSimpleSequence(t *testing.T) {
	arrows := arrows_1
	outcome := outcome_1
	settings := settings_1
	goldenTest(t, settings, arrows, outcome)
}

func TestSequenceCrash(t *testing.T) {
	arrows := arrows_2
	outcome := outcome_2
	settings := settings_2
	goldenTest(t, settings, arrows, outcome)
}

var theResultThatWeStoreForBenchmarking []byte

// run with `go test -bench=Sequence -run XXX`
func benchmarkSequence(many int, b *testing.B) {
	arrows := make([]Arrow, 0, len(arrows_1)*many)
	for i := 0; i < many; i++ {
		// maybe use copy and changing slice? Doesn't matter, we reset timer anyways
		for _, arr := range arrows_1 {
			arrows = append(arrows, arr)
		}
	}
	settings := settings_1

	b.ResetTimer()
	// we want to store the result to a package level var so that it doesn't get optimized
	// away
	var r []byte
	for i := 0; i < b.N; i++ {
		_, r, _ = DrawDiagram(arrows, settings)
	}
	theResultThatWeStoreForBenchmarking = r
}

func BenchmarkSequence1(b *testing.B)    { benchmarkSequence(1, b) }
func BenchmarkSequence2(b *testing.B)    { benchmarkSequence(2, b) }
func BenchmarkSequence5(b *testing.B)    { benchmarkSequence(5, b) }
func BenchmarkSequence10(b *testing.B)   { benchmarkSequence(10, b) }
func BenchmarkSequence50(b *testing.B)   { benchmarkSequence(50, b) }
func BenchmarkSequence100(b *testing.B)  { benchmarkSequence(100, b) }
func BenchmarkSequence1000(b *testing.B) { benchmarkSequence(1000, b) }
