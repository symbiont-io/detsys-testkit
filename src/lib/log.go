package lib

import (
	"database/sql"
	"time"
)

// Deprecated: will be removed in the future
func AddLogStamp(db *sql.DB, testId TestId, runId RunId, component string, message []byte, at time.Time) {
	stmt, err := db.Prepare(`INSERT INTO log_trace (test_id, run_id, id, component, log, simulated_time)
VALUES (?, ?, (SELECT IFNULL(MAX(id), -1) + 1 FROM log_trace WHERE test_id = ? AND run_id = ?), ?, ?, ?)
`)
	if err != nil {
		panic(err)
	}
	defer stmt.Close()

	if _, err = stmt.Exec(testId.TestId, runId.RunId, testId.TestId, runId.RunId, component, message, at.Format(time.RFC3339Nano)); err != nil {
		panic(err)
	}
}
