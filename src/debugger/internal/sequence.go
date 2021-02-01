package debugger

import (
	"strings"
)

// inlined version of b.WriteString(strings.Repeat(s,count))
func WriteRepeat(b *strings.Builder, s string, count int) {
	if count == 0 {
		return
	}

	// Since we cannot return an error on overflow,
	// we should panic if the repeat will generate
	// an overflow.
	// See Issue golang.org/issue/16237
	if count < 0 {
		panic("strings: negative Repeat count")
	} else if len(s)*count/count != len(s) {
		panic("strings: Repeat count causes overflow")
	}

	n := len(s) * count
	origLen := b.Len()
	on := n + origLen
	b.WriteString(s)
	for b.Len() < on {
		if b.Len()-origLen <= n/2 {
			b.WriteString(b.String()[origLen:])
		} else {
			b.WriteString(b.String()[origLen:][:on-b.Len()])
			break
		}
	}
}

type Arrow struct {
	From    string
	To      string
	Message string
	Dropped bool
}

type arrowInternal struct {
	from               int
	to                 int
	message            string
	dropped            bool
	goingRight         bool
	gapIndexToAnnotate int
	annotationLeft     string
	annotationRight    string
}

func boxSize(names []string) int {
	boxSize := 3
	for _, name := range names {
		this := 4 + len(name) + (len(name)+1)%2
		if boxSize < this {
			boxSize = this
		}
	}
	return boxSize
}

const hLine = "─"

func hline(len int) string {
	return strings.Repeat(hLine, len)
}

func wline(len int) string {
	return strings.Repeat(" ", len)
}

const dLine = "╌"

func dline(len int) string {
	return strings.Repeat(dLine, len)
}

func appendBoxes(isTop bool, output *strings.Builder, names []string, gaps []int) {
	boxSize := boxSize(names)
	// top of the boxes
	{
		middle := "┴"
		if isTop {
			middle = "─"
		}

		halfPoint := (boxSize - 2) / 2
		for i, _ := range names {
			WriteRepeat(output, " ", gaps[i])
			output.WriteString("╭")
			WriteRepeat(output, hLine, halfPoint)
			output.WriteString(middle)
			WriteRepeat(output, hLine, halfPoint)
			output.WriteString("╮")
		}
		output.WriteString("\n")
	}
	// content of boxes
	{
		for i, name := range names {
			totalSpace := boxSize - 4 - len(name)
			slack := totalSpace / 2
			remaining := totalSpace - slack
			WriteRepeat(output, " ", gaps[i])
			output.WriteString("│ ")
			WriteRepeat(output, " ", slack)
			output.WriteString(name)
			WriteRepeat(output, " ", remaining)
			output.WriteString(" │")
		}
		output.WriteString("\n")
	}
	// bottom of boxes
	{
		var middle string
		if isTop {
			middle = `┬`
		} else {
			middle = `─`
		}

		halfPoint := (boxSize - 2) / 2

		for i, _ := range names {
			WriteRepeat(output, " ", gaps[i])
			output.WriteString("╰")
			WriteRepeat(output, hLine, halfPoint)
			output.WriteString(middle)
			WriteRepeat(output, hLine, halfPoint)
			output.WriteString("╯")
		}
		output.WriteString("\n")
	}
}

func appendArrows(output *strings.Builder, names []string, arrows []arrowInternal, gaps []int, boxSize int) {
	for _, arr := range arrows {
		halfBox := boxSize / 2
		{
			for i, _ := range names {
				if i == arr.gapIndexToAnnotate {
					totalSpace := 2*halfBox + gaps[i] - len(arr.message)
					slack := totalSpace / 2
					WriteRepeat(output, " ", slack)
					output.WriteString(arr.annotationLeft)
					output.WriteString(arr.message)
					output.WriteString(arr.annotationRight)
					WriteRepeat(output, " ", totalSpace-slack)
				} else {
					space := halfBox + gaps[i]
					if i != 0 {
						space += halfBox
					}
					WriteRepeat(output, " ", space)
				}
				output.WriteString("│")
			}
			output.WriteString("\n")
		}

		halfEmpty := wline(halfBox)
		halfFull := hline(halfBox)
		if arr.dropped {
			halfFull = dline(halfBox)
		}

		if arr.to == arr.from {
			//compute top of loop
			for i, _ := range names {
				leftPart := halfEmpty
				middle := "│"
				rightPart := halfEmpty

				WriteRepeat(output, " ", gaps[i])
				if i == arr.from {
					if arr.goingRight {
						middle = "├"
						rightPart = hline(halfBox-1) + "╮"
					} else {
						middle = "┤"
						leftPart = "╭" + hline(halfBox-1)
					}
				}

				output.WriteString(leftPart)
				output.WriteString(middle)
				output.WriteString(rightPart)

			}
			output.WriteString("\n")
			//compute bottom line of loop
			for i, _ := range names {
				WriteRepeat(output, " ", gaps[i])
				leftPart := halfEmpty
				middle := "│"
				rightPart := halfEmpty

				if i == arr.from {
					if arr.goingRight {
						middle = "◀"
						rightPart = hline(halfBox-1) + "╯"
					} else {
						middle = "▶"
						leftPart = "╰" + hline(halfBox-1)
					}
				}

				output.WriteString(leftPart)
				output.WriteString(middle)
				output.WriteString(rightPart)
			}
			output.WriteString("\n")
		} else {
			for i, _ := range names {
				leftPart := halfEmpty
				middle := "│"
				rightPart := halfEmpty
				if (arr.goingRight && arr.from < i && i <= arr.to) ||
					(!arr.goingRight && arr.to < i && i <= arr.from) {
					if arr.dropped {
						WriteRepeat(output, dLine, gaps[i])
					} else {
						WriteRepeat(output, hLine, gaps[i])
					}
				} else {
					WriteRepeat(output, " ", gaps[i])
				}

				if (arr.goingRight && arr.from < i && i <= arr.to) ||
					(!arr.goingRight && arr.to < i && i <= arr.from) {
					leftPart = halfFull
				}
				output.WriteString(leftPart)

				if arr.goingRight {
					if i == arr.from {
						middle = "├"
					}
					if i == arr.to {
						middle = "▶"
					}
					if arr.from < i && i < arr.to {
						middle = "┼"
					}
				} else {
					if i == arr.from {
						middle = "┤"
					}
					if i == arr.to {
						middle = "◀"
					}
					if arr.to < i && i < arr.from {
						middle = "┼"
					}
				}
				output.WriteString(middle)

				if arr.goingRight && arr.from <= i && i < arr.to {
					rightPart = halfFull
				} else if !arr.goingRight && arr.to <= i && i < arr.from {
					rightPart = halfFull
				}
				output.WriteString(rightPart)
			}
			output.WriteString("\n")
		}
	}
}

func drawDiagram(names []string, arrows []arrowInternal, gaps []int, nrLoops int) []byte {
	if len(names) < 1 {
		panic("We need at least one box")
	}

	boxSize := boxSize(names)

	var output strings.Builder
	var expectedSize int
	{
		var lineWidth int
		for _, gap := range gaps {
			lineWidth += gap
		}
		lineWidth += boxSize * len(names)
		lineWidth++                                        // newline
		expectedSize = lineWidth * (len(arrows) + nrLoops) // loops have one more line than normal
	}
	output.Grow(expectedSize)

	appendBoxes(true, &output, names, gaps)
	appendArrows(&output, names, arrows, gaps, boxSize)
	appendBoxes(false, &output, names, gaps)

	// remove last newline
	return []byte(output.String()[:output.Len()-1])
}

func index(haystack []string, needle string) int {
	for i, v := range haystack {
		if v == needle {
			return i
		}
	}
	return -1
}

type DrawSettings struct {
	MarkerSize int
	MarkAt     int
}

func DrawDiagram(arrows []Arrow, settings DrawSettings) []byte {
	var names []string
	{
		for _, arr := range arrows {
			if index(names, arr.From) == -1 {
				names = append(names, arr.From)
			}
			if index(names, arr.To) == -1 {
				names = append(names, arr.To)
			}
		}

	}
	gaps := make([]int, len(names), len(names))
	arrowsInternal := make([]arrowInternal, 0, len(arrows))
	allocatedMarkerSize := 2 * settings.MarkerSize
	nrLoops := 0
	emptyMarker := strings.Repeat(" ", settings.MarkerSize)
	leftMarker := strings.Repeat(">", settings.MarkerSize)
	rightMarker := strings.Repeat("<", settings.MarkerSize)
	for i, arr := range arrows {
		from := index(names, arr.From)
		to := index(names, arr.To)

		if from == to {
			nrLoops++
		}

		goingRight := true
		if to < from {
			goingRight = false
		}
		gapIndexToAnnotate := from
		if goingRight {
			gapIndexToAnnotate++
		}

		// if we are a self-loop at the end, we make special case
		if from == to && from == len(names)-1 {
			goingRight = false
			gapIndexToAnnotate = from
		}

		if gaps[gapIndexToAnnotate] < len(arr.Message)+allocatedMarkerSize {
			gaps[gapIndexToAnnotate] = len(arr.Message) + allocatedMarkerSize
		}
		var message string
		annotationLeft := ""
		annotationRight := ""
		if i == settings.MarkAt {
			annotationLeft = "[yellow]"
			annotationRight = "[-]"
			message = leftMarker + arr.Message + rightMarker
		} else {
			message = emptyMarker + arr.Message + emptyMarker
		}
		arrowsInternal = append(arrowsInternal, arrowInternal{
			from:               from,
			to:                 to,
			message:            message,
			dropped:            arr.Dropped,
			goingRight:         goingRight,
			gapIndexToAnnotate: gapIndexToAnnotate,
			annotationLeft:     annotationLeft,
			annotationRight:    annotationRight,
		})
	}

	boxSize := boxSize(names)
	for i, gap := range gaps {
		if gap < boxSize-1 {
			gaps[i] = 0
		} else {
			gaps[i] = gap - (boxSize - 1)

		}
	}

	return drawDiagram(names, arrowsInternal, gaps, nrLoops)
}