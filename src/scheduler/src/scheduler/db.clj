(ns scheduler.db
  (:require [clojure.java.shell :as shell]
            [scheduler.spec :refer [>defn =>]]
            [next.jdbc :as jdbc]
            [next.jdbc.sql :as sql]
            [next.jdbc.result-set :as rs]
            [scheduler.json :as json]
            [scheduler.time :as time]))

(set! *warn-on-reflection* true)

(def db nil)
(def ds nil)

(defn setup-db
  [db-file]
  (alter-var-root #'db
                  (constantly {:dbtype "sqlite" :dbname db-file}))
  (alter-var-root #'ds
                  (constantly (jdbc/get-datasource db))))

(defn read-db!
  "Import an SQLite database dump."
  [db-file dump-file]
  (shell/sh "sqlite3" db-file :in (str ".read " dump-file)))

(defn load-test!
  [test-id]
  (->> (jdbc/execute!
        ds
        ["SELECT * FROM agenda WHERE test_id = ? ORDER BY id ASC" test-id]
        {:return-keys true :builder-fn rs/as-unqualified-lower-maps})
       (mapv #(-> %
                  (dissoc :id :test_id)
                  (update :at time/instant)
                  (update :args json/read)))))

(defn create-run!
  [test-id seed]
  (jdbc/execute-one!
   ds
   ["INSERT INTO run (test_id, id, seed)
     VALUES (?, (SELECT IFNULL(MAX(id), -1) + 1 FROM run WHERE test_id = ?), ?)"
    test-id test-id seed])
  (jdbc/execute-one!
   ds
   ["SELECT MAX(id) as `run-id` FROM run WHERE test_id = ?" test-id]
   {:return-keys true :builder-fn rs/as-unqualified-lower-maps}))

(defn append-history!
  [test-id run-id kind event args process]
  (jdbc/execute-one!
   ds
   ["INSERT INTO history (test_id, run_id, id, kind, event, args, process)
     VALUES (?, ?, (SELECT IFNULL(MAX(id), -1) + 1 FROM history WHERE run_id = ?), ?, ?, ?, ?)"
    test-id run-id run-id (name kind) event args process]
   {:return-keys true :builder-fn rs/as-unqualified-lower-maps}))

(comment
  (setup-db "/tmp/test.sqlite3")
  (destroy-db!)
  (create-db!)
  (create-test!)
  (insert-agenda! 1 0 "invoke" "inc" "{\"id\": 1}" "client:0" "node1" "1970-01-01T00:00:00Z")
  (insert-agenda! 1 1 "invoke" "get" "{\"id\": 1}" "client:0" "node1" "1970-01-01T00:00:01Z")
  (load-test! 1)
  (create-run! 0 123)
  (append-history! 1 :invoke "a" "{\"id\": 1}" 0))

(defn append-trace!
  [test-id run-id message args kind from to sent-logical-time at dropped?]
  (jdbc/execute-one!
   ds
   ["INSERT INTO network_trace (test_id, run_id, id, message, args, kind, `from`, `to`, sent_logical_time, at, dropped)
     VALUES (?, ?, (SELECT IFNULL(MAX(id), -1) + 1 FROM network_trace WHERE test_id = ? AND run_id = ?), ?, ?, ?, ?, ?, ?, ?, ?)"
    test-id run-id test-id run-id message args kind from to sent-logical-time at (if dropped? 1 0)]
   {:return-keys true :builder-fn rs/as-unqualified-lower-maps}))

(defn append-time-mapping!
  [test-id run-id logical-time simulated-time]
  (jdbc/execute-one!
   ds
   ["INSERT INTO time_mapping (test_id, run_id, logical_time, simulated_time)
      VALUES (?, ?, ?, ?)"
    test-id run-id logical-time simulated-time]
   {:return-keys true :builder-fn rs/as-unqualified-lower-maps}))

(defn append-event!
  [test-id run-id event data]
   (jdbc/execute-one!
    ds
    ["INSERT INTO event_log (event, meta, data) VALUES (?,?,?)"
     event
     (json/write {:component "scheduler"
                  :test-id test-id
                  :run-id run-id})
     (json/write data)]
    {:return-keys true :builder-fn rs/as-unqualified-lower-maps}))

;; Remove this when we no longer use the old events
(defn append-old-network-history-events!
  [test-id run-id data]
  (append-trace! test-id run-id (:message data) (json/write (:args data)) (:kind data) (:from data) (:to data) (:sent-logical-time data) (:recv-logical-time data) (:dropped data)))

(defn append-network-trace!
  [test-id run-id data]
  (append-event! test-id run-id "NetworkTrace" data)
  ;; This should be removed when everything has been refactored to new
  ;; events.
  (append-old-network-history-events! test-id run-id data))
