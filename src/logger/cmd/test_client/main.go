package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

func log(w *bufio.Writer, event []byte, meta []byte, data []byte) {
	entry, err := json.Marshal(map[string][]byte{
		"event": event,
		"meta":  meta,
		"data":  data,
	})
	if err != nil {
		panic(err)
	}
	fmt.Printf("entry = '%s'\n", string(entry))
	_, err = w.Write(append(entry, byte('\n')))
	if err != nil {
		panic(err)
	}
	if err := w.Flush(); err != nil {
		panic(err)
	}
}

func main() {
	namedPipe := filepath.Join(os.TempDir(), "detsys-logger")
	fh, err := os.OpenFile(namedPipe, os.O_WRONLY, 0600)
	defer fh.Close()
	if err != nil {
		panic(err)
	}
	w := bufio.NewWriter(fh)

	for i := 0; i < 5; i++ {
		if i%2 == 0 {
			fmt.Printf("Writing... i = %d\n", i)

		}
		log(w, []byte("TestEvent"),
			[]byte(`{"component":"test_client", "test_id":0, "run_id":0}`),
			[]byte(fmt.Sprintf(`{"args":{"index": %d}}`, i)),
		)
	}
}
