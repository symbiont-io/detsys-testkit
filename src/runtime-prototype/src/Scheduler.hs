{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Scheduler where

import Control.Concurrent.Async
import Control.Exception
import Control.Exception (throwIO)
import Data.Aeson
import Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Char (toLower)
import Data.Heap (Entry(Entry), Heap)
import qualified Data.Heap as Heap
import Data.Maybe (fromJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time (UTCTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.IO.Error (catchIOError, isDoesNotExistError)

import StuntDouble

------------------------------------------------------------------------

data SchedulerEvent = SchedulerEvent
  { kind  :: String
  , event :: String
  , args  :: Data.Aeson.Value
  , to    :: String
  , from  :: String
  , at    :: UTCTime
  , meta  :: Maybe Meta
  }
  deriving (Generic, Eq, Ord, Show)

instance FromJSON SchedulerEvent
instance ToJSON SchedulerEvent

data Meta = Meta
  { test_id      :: Int
  , run_id       :: Int
  , logical_time :: Int
  }
  deriving (Generic, Eq, Ord, Show)

instance ToJSON Meta where
  toEncoding = genericToEncoding defaultOptions
    -- The executor expects kebab-case.
    { fieldLabelModifier = map (\c -> if c == '_' then '-' else c) }

instance FromJSON Meta where

data SchedulerState = SchedulerState
  { heap   :: Heap (Entry UTCTime SchedulerEvent)
  , time   :: UTCTime
  , seed   :: Seed
  , steps  :: Int
  , testId :: Maybe Int
  , runId  :: Maybe Int
  }

initState :: UTCTime -> Seed -> SchedulerState
initState t s = SchedulerState
  { heap   = Heap.empty
  , time   = t
  , seed   = s
  , steps  = 0
  , testId = Nothing
  , runId  = Nothing
  }

data Agenda = Agenda [SchedulerEvent]

instance ParseRow Agenda where
  -- XXX: Text -> ByteString -> JSON, seems unnecessary? We only need the `at`
  -- field for the heap priority, the rest could remain as a text and sent as
  -- such to the executor?
  parseRow [FText t] = case eitherDecodeStrict (Text.encodeUtf8 t) of
    Right es -> Just (Agenda es)
    Left err -> error (show err)
  parseRow x         = error (show x)

-- echo "{\"tag\":\"InternalMessage'\",\"contents\":[\"CreateTest\",[{\"tag\":\"SInt\",\"contents\":0}]]}" | http POST :3005 && echo "{\"tag\":\"InternalMessage'\",\"contents\":[\"Start\",[]]}" | http POST :3005

fakeScheduler :: RemoteRef -> Message -> Actor SchedulerState
fakeScheduler executorRef (ClientRequest' "CreateTest" [SInt tid] cid) = Actor $ do
  p <- asyncIO (IOQuery "SELECT agenda FROM test_info WHERE test_id = :tid" [":tid" := tid])
  q <- asyncIO (IOQuery "SELECT IFNULL(MAX(run_id), -1) + 1 FROM run_info WHERE test_id = :tid"
                [":tid" := tid])
  on p (\(IOResultR (IORows rs)) -> case parseRows rs of
           Nothing          -> clientResponse cid (InternalMessage "parse error")
           Just [Agenda es] -> do
             modify $ \s ->
               s { heap   = Heap.fromList (map (\e -> Entry (at e) e) es)
                 , testId = Just tid
                 }
             clientResponse cid (InternalMessage (show es)))
  -- XXX: combine `on (p and q)` somehow? the current way we can respond to the
  -- client without having set the runId... Also this current way we can't
  -- really handle an error for the run id select?
  on q (\(IOResultR (IORows [[FInt rid]])) ->
           modify $ \s -> s { runId = Just rid })
  return (InternalMessage "ok")
fakeScheduler executorRef (ClientRequest' "Start" [] cid) =
  let
    step = do
      r <- Heap.uncons . heap <$> get
      case r of
        Just (Entry time e, heap') -> do
          modify $ \s -> s { heap  = heap'
                           , time  = time
                           , steps = succ (steps s)
                           }
          p <- send executorRef (InternalMessage (prettyEvent e))
          on p (\(InternalMessageR (InternalMessage' "Events" args)) -> do
                  -- XXX: we should generate an arrival time here using the seed.
                  -- XXX: with some probability duplicate the event?
                  let Just evs = sequence (map (fromSDatatype time) args)
                      evs' = filter (\e -> kind e /= "ok") (concat evs)
                      heap' = Heap.fromList (map (\e -> Entry (at e) e) evs')
                  modify $ \s -> s { heap = heap s `Heap.union` heap' }
                  step
               )
        Nothing -> do
          -- The format looks at follows:
          -- LogSend _from (InternalMessage "{\"event\":\"write\",\"args\":{\"value\":1},\"at\":\"1970-01-01T00:00:00Z\",\"kind\":\"invoke\",\"to\":\"frontend\",\"from\":\"client:0\",\"meta\":null}") _to
          -- For network_trace we need:
          -- CREATE VIEW network_trace AS
          --  SELECT
          --    ...
          --    json_extract(data, '$.sent-logical-time')   AS sent_logical_time,
          --    json_extract(data, '$.recv-logical-time')   AS recv_logical_time,
          --    json_extract(data, '$.recv-simulated-time') AS recv_simulated_time,
          --    json_extract(data, '$.dropped')             AS dropped
          --
          -- `sent-logical-time`, can be saved in `LogSend`:
          --
          --    sent-logical-time (or (-> body :sent-logical-time)
          --                          (and is-from-client?
          --                               (:logical-clock data)))]
          -- `recv-logical-time` is `logical-clock` of the next entry
          -- `recv-simulated-time` is `clock` of the next entry

          l <- dumpLog
          s <- get

          -- XXX: something like this needs to be done for each log entry:
          -- p <- asyncIO (IOExecute "INSERT INTO event_log (event, meta, data) \
          --                         \ VALUES (:event, :meta, :data)"
          --                [ ":event" := ("NetworkTrace" :: String)
          --                , ":meta"  := encode (object
          --                                       [ "component" .= ("scheduler" :: String)
          --                                       , "test-id"   .= maybe (error "test id not set") id
          --                                                          (testId s)
          --                                       , "run-id"    .= maybe (error "run id not set") id
          --                                                          (runId s)
          --                                       ])
          --                , ":data"  := encode (object []) -- XXX:
          --                ])

          clientResponse cid (InternalMessage ("{\"steps\":" ++ show (steps s) ++
                                               ",\"test_id\":" ++ show (testId s) ++
                                               ",\"run_id\":" ++ show (runId s) ++
                                               ",\"event_log\":" ++ show l ++
                                               "}"))
  in
    Actor $ do
      step
      return (InternalMessage "ok")
  where
    prettyEvent :: SchedulerEvent -> String
    prettyEvent = LBS.unpack . encode
fakeScheduler _ msg = error (show msg)

-- XXX: Avoid going to string, not sure if we should use bytestring or text though?
entryToData :: Int -> Int -> UTCTime -> Bool -> Timestamped LogEntry -> String
entryToData slt rlt rst d (Timestamped (LogSend _from _to (InternalMessage msg)) _logicalTimestamp _t)
  = addField "sent-logical-time" (show slt) -- XXX: we cannot use _logicalTimestamp
                                            -- here, because its when the event
                                            -- loop sent the message to the
                                            -- executor rather than what we
                                            -- want: when the actor sent the
                                            -- message to the other actor.
  . addField "recv-logical-time" (show rlt)
  . addField "recv-simulated-time" (show (encode rst))
  . addField "dropped" (if d then "true" else "false")
  . replaceEventMessage
  $ msg
  where
    replaceEventMessage ('{' : '"' : 'e' : 'v' : 'e' : 'n' : 't' : msg') = "{\"message" ++ msg'
    addField f v ('{' : msg') = "{\"" ++ f ++ "\":" ++ v ++ "," ++ msg'

executorCodec :: Codec
executorCodec = Codec encode decode
  where
    encode :: Envelope -> Encode
    encode e = Encode (address (envelopeReceiver e))
                      (getCorrelationId (envelopeCorrelationId e))
                      (LBS.pack (getMessage (envelopeMessage e)))

    decode :: ByteString -> Either String Envelope
    decode bs = case eitherDecode bs of
      Right (ExecutorResponse evs corrId) -> Right $
        Envelope
          { envelopeKind             = ResponseKind
          , envelopeSender           = RemoteRef "executor" 0
          -- XXX: going to sdatatype here seems suboptimal...
          , envelopeMessage          = InternalMessage' "Events" (map toSDatatype evs)
          , envelopeReceiver         = RemoteRef "scheduler" 0
          , envelopeCorrelationId    = corrId
          , envelopeLogicalTimestamp = LogicalTimestamp "executor" (-1)
          }
      Left err -> error err

data ExecutorResponse = ExecutorResponse
  { events :: [UnscheduledEvent]
  , corrId :: CorrelationId
  }
  deriving (Generic, Show)

instance FromJSON ExecutorResponse

data UnscheduledEvent = UnscheduledEvent
  { ueKind  :: String
  , ueEvent :: String
  , ueArgs  :: Data.Aeson.Value
  , ueTo    :: [String]
  , ueFrom  :: String
  }
  deriving (Generic, Eq, Ord, Show)

instance FromJSON UnscheduledEvent where
  parseJSON = genericParseJSON defaultOptions
    { fieldLabelModifier = \s -> case drop (length ("ue" :: String)) s of
        (x : xs) -> toLower x : xs
        [] -> error "parseJSON: impossible, unless the field names of `UnscheduledEvent` changed" }

toSDatatype :: UnscheduledEvent -> SDatatype
toSDatatype (UnscheduledEvent kind event args to from) =
  SList [SString kind, SString event, SValue args, SList (map SString to), SString from]

fromSDatatype :: UTCTime -> SDatatype -> Maybe [SchedulerEvent]
fromSDatatype at (SList
  [SString kind, SString event, SValue args, SList tos, SString from])
  = Just [ SchedulerEvent kind event args to from at Nothing | SString to <- tos ]
fromSDatatype _at _d = Nothing

getDbPath :: IO FilePath
getDbPath = do
  getEnv "DETSYS_DB"
    `catchIOError` \(e :: catchIOError) ->
      if isDoesNotExistError e
        then do
          home <- getEnv "HOME"
          return (home </> ".detsys.db")
        else throwIO e

main :: String -> IO ()
main version = do
  let executorPort = 3001
      executorRef = RemoteRef ("http://localhost:" ++ show executorPort ++ "/api/v1/event") 0
      schedulerPort = 3005
  fp <- getDbPath
  el <- makeEventLoop realTime (makeSeed 0) HttpSync (AdminNamedPipe "/tmp/")
          executorCodec (RealDisk fp) (EventLoopName "scheduler")
  now <- getCurrentTime realTime
  lref <- spawn el (fakeScheduler executorRef) (initState now (makeSeed 0))
  withHttpFrontend el lref schedulerPort $ \pid -> do
    putStrLn ("Scheduler (version " ++ version ++ ") is listening on port: " ++ show schedulerPort)
    waitForEventLoopQuit el
    cancel pid
