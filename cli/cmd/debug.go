package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"

	"github.com/spf13/cobra"
	"github.com/symbiont-io/detsys/lib"
)

var debugCmd = &cobra.Command{
	Use:   "debug [test-id] [run-id]",
	Short: "Debug a test run",
	Long:  ``,
	Args:  cobra.ExactArgs(2),
	Run: func(_ *cobra.Command, args []string) {
		testId, err := lib.ParseTestId(args[0])
		if err != nil {
			panic(err)
		}
		runId, err := lib.ParseRunId(args[1])
		if err != nil {
			panic(err)
		}
		cmd := exec.Command("../debugger/cmd/cmd",
			strconv.Itoa(testId.TestId),
			strconv.Itoa(runId.RunId))

		out, err := cmd.CombinedOutput()

		if err != nil {
			fmt.Printf("%s\n", out)
			os.Exit(1)
		}
	},
}
