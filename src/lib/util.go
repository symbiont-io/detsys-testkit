package lib

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type TestId struct {
	TestId int
}

func (testId *TestId) UnmarshalJSON(b []byte) error {
	var i int
	if err := json.Unmarshal(b, &i); err != nil {
		return err
	}
	testId.TestId = i
	return nil
}

func (testId TestId) MarshalJSON() ([]byte, error) {
	return []byte(strconv.Itoa(testId.TestId)), nil
}

const schedulerUrl string = "http://localhost:3000"

type SchedulerRequest struct {
	Command    string      `json:"command"`
	Parameters interface{} `json:"parameters"`
}

func Post(command string, parameters interface{}) []byte {
	json, err := json.Marshal(SchedulerRequest{
		Command:    command,
		Parameters: parameters})
	if err != nil {
		log.Panicln(err)
	}
	resp, err := http.Post(schedulerUrl, "application/json", bytes.NewBuffer(json))
	if err != nil {
		log.Panicln(err)
	}
	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		log.Panicln(err)
	}
	if resp.StatusCode != 200 {
		log.Panicln(string(body))
	}
	return body
}

func PostParse(command string, parameters interface{}, target interface{}) {
	body := Post(command, parameters)
	if err := json.Unmarshal(body, &target); err != nil {
		log.Panicln(err)
	}
}

func ParseTestId(s string) (TestId, error) {
	i, err := strconv.Atoi(s)
	if err != nil {
		return TestId{}, err
	}
	return TestId{i}, nil
}

func ParseRunId(s string) (RunId, error) {
	i, err := strconv.Atoi(s)
	if err != nil {
		return RunId{}, err
	}
	return RunId{i}, nil
}

func DBPath() string {
	path, ok := os.LookupEnv("DETSYS_DB")
	if !ok {
		path = os.Getenv("HOME") + "/.detsys.db"
	}
	return path
}

func OpenDB() *sql.DB {
	path := DBPath()
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		panic(err)
	}
	return db
}

type DeploymentInfo struct {
	Reactor string          `json:"reactor"`
	Type    string          `json:"type"`
	Args    json.RawMessage `json:"args"`
}

func DeploymentInfoForTest(testId TestId) ([]DeploymentInfo, error) {
	db := OpenDB()
	defer db.Close()

	rows, err := db.Query(`SELECT deployment
                              FROM test_info
                              WHERE test_id = ?`, testId.TestId)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var deployments = make([]DeploymentInfo, 0)
	found_one := false
	for rows.Next() {
		// we should only find one test with a given test-id
		if found_one {
			return nil, errors.New(fmt.Sprintf("We found multiple tests with id: %d", testId.TestId))
		}
		found_one = true

		var jsonBlob []byte
		err := rows.Scan(&jsonBlob)
		if err != nil {
			return nil, err
		}
		var columns []DeploymentInfo
		err = json.Unmarshal(jsonBlob, &columns)

		if err != nil {
			return nil, err
		}

		for _, column := range columns {
			deployments = append(deployments, column)
		}
	}

	return deployments, nil
}

type TimeFromString time.Time

func (tf *TimeFromString) Scan(src interface{}) error {
	switch t := src.(type) {
	case string:
		tp, err := time.Parse(time.RFC3339Nano, t)
		if err != nil {
			return err
		}
		*tf = TimeFromString(tp)
		return err
	case []byte:
		tp, err := time.Parse(time.RFC3339Nano, string(t))
		if err != nil {
			return err
		}
		*tf = TimeFromString(tp)
		return err
	case *time.Time:
		*tf = (TimeFromString)(*t)
		return nil
	default:
		return errors.New(fmt.Sprintf("Invalid type %T can't be parses to a TimeFromString", t))
	}
}
