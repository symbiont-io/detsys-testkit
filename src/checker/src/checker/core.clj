(ns checker.core
  (:require [clojure
             [pprint :refer [pprint]]
             [edn :as edn]]
            [clojure.java.io :as io]
            [elle [core :as elle]
             [list-append :as list-append]
             [rw-register :as rw-register]]
            [checker.db :as db]
            [me.raynes.fs :as fs])
  (:import (java.io PushbackReader)
           [lockfix LockFix])
  (:gen-class))

(set! *warn-on-reflection* true)

;; patched version of clojure.core/locking to workaround GraalVM unbalanced
;; monitor issue. Compile lockfix with:
;; javac java/src/lockfix/LockFix.java -cp \
;;       ~/.m2/repository/org/clojure/clojure/1.10.2-alpha1/clojure-1.10.2-alpha1.jar
(defmacro locking*
  "Executes exprs in an implicit do, while holding the monitor of x.
  Will release the monitor of x in all circumstances."
  {:added "1.0"}
  [x & body]
  `(let [lockee# ~x]
     (LockFix/lock lockee# (^{:once true} fn* [] ~@body))))

(let [orig (atom nil)
      monitor (Object.)]
  (defn log-capture!
    ([logger-ns]
     (log-capture! logger-ns :info :error))
    ([logger-ns out-level err-level]
     (locking* monitor
               (compare-and-set! orig nil [System/out System/err])
               (System/setOut  (#'clojure.tools.logging/log-stream out-level logger-ns))
               (System/setErr (#'clojure.tools.logging/log-stream err-level logger-ns)))))
  (defn log-uncapture!
    []
    (locking* monitor
              (when-let [[out err :as v] @orig]
                (swap! orig (constantly nil))
                (System/setOut out)
                (System/setErr err)))))

(alter-var-root #'clojure.tools.logging/log-capture! (constantly log-capture!))
(alter-var-root #'clojure.tools.logging/log-uncapture! (constantly log-uncapture!))

(defn checker-rw-register
  [test-id run-id]
  (-> (rw-register/check
       {:consistency-models [:strict-serializable]
        :linearizable-keys? true}
       (db/get-history :rw-register test-id run-id))
      (dissoc :also-not)))

(defn checker-list-append
  [test-id run-id]
  (let [dir (fs/temp-dir "detsys-elle")
        history (db/get-history :list-append test-id run-id)]
    (-> (list-append/check
         {:consistency-models [:strict-serializable]
          :directory dir}
         history)
        (dissoc :also-not)
        (assoc :elle-output (str dir)))))

;; Since the version is a constant GraalVM will evaluate it at compile-time, and
;; it will stay fixed independent of run-time values of the environment
;; variable.
(def gitrev ^String
  (or (System/getenv "DETSYS_CHECKER_VERSION")
      "unknown"))

(defn analyse
  [test-id run-id checker]
  (let [result (checker test-id run-id)
        valid? (:valid? result)]
    (db/store-result test-id run-id valid? result gitrev)
    (if valid?
      (System/exit 0)
      (do
        (pprint result)
        (System/exit 1)))))

(defn -main
  [& args]
  (let [arg0    (nth args 0 nil)
        test-id (nth args 1 nil)
        run-id  (nth args 2 nil)]
    (when (or (= arg0 "--version")
              (= arg0 "-v"))
      (do (println gitrev)
          (System/exit 0)))
    (db/setup-db (db/db))
    (case arg0
      "rw-register" (analyse (Integer/parseInt test-id) (Integer/parseInt run-id)
                             checker-rw-register)
      "list-append" (analyse (Integer/parseInt test-id) (Integer/parseInt run-id)
                             checker-list-append)
      (println
       "First argument should be a model, i.e. either \"rw-register\" or \"list-append\""))))

(comment
  (db/setup-db (db/db))
  (checker-list-append 1 0)

  (let [test-id 1
        run-id 0
        result (list-append/check
                {:consistency-models [:strict-serializable]
                 :directory "/tmp/test"}
                (db/get-history :list-append test-id run-id))
        valid? (:valid? result)]
  (db/store-result test-id run-id valid? result))

  (-> (list-append/check
       {:consistency-models [:strict-serializable]
        :directory "/tmp/test"}
       (db/get-history :list-append 1 0) ) )

  (let [test-id 2
        run-id 7
        dir "/tmp/test"]
  (-> (list-append/check
           {:consistency-models [:strict-serializable]
            :directory dir}
           (db/get-history :list-append test-id run-id))
          (dissoc :also-not)
          (assoc :elle-output (str dir))))

  (list-append/check
   [{:process 0, :index 0, :type :invoke, :f :txn, :value [[:append :x 1]]}
    {:process 0, :index 1, :type :ok, :f :txn, :value [[:append :x 1]]}
    {:process 0, :index 2, :type :invoke, :f :txn, :value [[:r :x nil]]}
    {:process 0, :index 3, :type :ok, :f :txn, :value [[:r :x [1]]]}])

  (analyse 1 0 checker-list-append)
  )
