(ns checker.json
  (:refer-clojure :exclude [read])
  (:require [jsonista.core :as j]))

(set! *warn-on-reflection* true)

(def mapper
  (j/object-mapper
   {:encode-key-fn true
    :decode-key-fn true}))

(defn read
  [s]
  (j/read-value s mapper))

(defn write
  [v]
  (j/write-value-as-string v mapper))
