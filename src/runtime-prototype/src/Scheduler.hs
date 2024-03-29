{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Scheduler where

import Control.Monad (forM)
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text.Encoding as Text
import Data.Fixed (Nano)
import Data.Time (UTCTime)
import qualified Data.Time.Clock as Time
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Scheduler.Agenda (Agenda)
import qualified Scheduler.Agenda as Agenda
import Scheduler.Event
import Scheduler.Executor
       (ExecutorResponse(ExecutorResponse), isOk, toScheduled, UnscheduledEvent)
import Scheduler.Fault (FaultState, manipulateEvent, manipulateOutGoingEvent, newFaultState, shouldDrop)
import Scheduler.Faults (Faults(Faults))
import Scheduler.State
import StuntDouble

------------------------------------------------------------------------

type Dropped = Bool
data SchedulerAction
  -- = Tick Time
  = Execute (Time, SchedulerEvent) Dropped
  | Done
  | TimeoutClient (Time, SchedulerEvent) Time -- XXX: what's the second time?

-- XXX: This will need some handling of faults
whatToDo :: {- RunInfo ref -> -} SchedulerState -> (SchedulerAction, SchedulerState)
whatToDo s0 = go s0
  where
    -- XXX: this comes from RunInfo
    clientTimeout = 20
    clientDelay = 20

    go :: SchedulerState -> (SchedulerAction, SchedulerState)
    go s =
      case Agenda.pop (agenda s) of
        Nothing -> (Done, s)
        Just (ev@(t, event), agenda') ->
          case lookupClient (from event) s of
            Nothing ->
              let toDrop = shouldDrop ev (logicalTime s) (faultState s)
              in (Execute ev toDrop, s { agenda = agenda' })
            Just t' ->
              let
                now :: Time
                now = time s
              in
              if now `afterTime` (t' `addTime` clientTimeout)
              then (TimeoutClient ev now, s { agenda = agenda' })
              else
                -- Update time. XXX: explain why?
                go (s { agenda = Agenda.push (t `addTime` clientDelay, event) agenda' })

  {-
emitEvent :: Monad m =>
  Trace.Capability m ->
  Client.Capability m ->
  TestId -> RunId -> Dropped -> Time.LogicalTime -> AgendaEntry -> m ()
emitEvent traceC clientC tid rid d now ae = do
  mclient <- clientP clientC (from $ Agenda.theEvent ae) (to $ Agenda.theEvent ae)
  Trace.emitEvent traceC tid rid (traceEvent d False now mclient ae)
-}

  {-
partitionOutEvent :: Monad m => Client.Capability m -> Time.LogicalTime ->
  Executor.Events -> m ([ClientResponse], [(Event, Maybe Time.Duration)])
partitionOutEvent clientC now = fmap Either.partitionEithers . mapM f . sort . concatMap translate
  where
    -- f :: (Event, Maybe Time.Duration) -> m (Either ClientResponse Event)
    f (e, d) = do
      mc <- Client.isClient clientC (to e)
      case mc of
        Nothing -> return $ Right (e, d)
        Just _p -> do
          -- should we deActivateClient here?
          Client.deActivateClient clientC (to e)
          return $ Left $ ClientResponse e

    kindTy Executor.Ok = "ok"
    kindTy Executor.Message = "message"

    kindTimerTy Executor.Timer = "timer"

    translate :: Executor.OutEvent -> [(Event, Maybe Time.Duration)]
    translate (Executor.OEUnscheduledEvent use) = do
      toA <- Executor.ueTo use
      return (Event
              { kind = kindTy (Executor.ueKind use),
                event = Executor.ueEvent use,
                args = Executor.ueArgs use,
                to = toA,
                from = Executor.ueFrom use,
                sentAt = Just (Time.theLogicalTime now)
              }, Nothing)
    translate (Executor.OETimer te) =
      return (Event
              { kind = kindTimerTy (Executor.teKind te),
                event = "timer",
                args = Executor.teArgs te,
                to = Executor.teFrom te, -- note we use from
                from = Executor.teFrom te,
                sentAt = Just (Time.theLogicalTime now)
              }, Just $ Executor.teDuration te)
-}

  {-
resolveClientResponses :: Monad m => TestId -> RunId -> RunInfo ref
  -> Time.Capability m
  -> [ClientResponse] -> m ()
resolveClientResponses _testId _runId _runInfo _timeC [] = pure ()
resolveClientResponses _testId _runId _runInfo timeC _cr = do
  now <- Time.currentSimulatedClock timeC
  -- we set the time to the same, but we bump the logical time
  Time.advanceTime timeC now Time.BumpLogical
  -- TODO
  -- we should emit events here
  pure ()
-}

data WithRandom = NoRandom | WithMean Double

randomList :: WithRandom -> Int -> Free (ActorF s) [Double]
randomList NoRandom len = return $ replicate len 0
randomList (WithMean mean) len = randomListOfExp len mean

scheduleAgenda :: Time -> WithRandom -> [UnscheduledEvent] -> Free (ActorF s) Agenda
scheduleAgenda t wr evs = do
  ts <- map (addTime t . fromRational . toRational . realToFrac @Double @Nano)
        <$> randomList wr (length evs)
  let evs' = concat (zipWith toScheduled ts evs)
  return $ Agenda.fromList (map (\e -> (at e, e)) evs')

manipulateOutgoing :: Time -> FaultState -> [UnscheduledEvent] -> Free (ActorF s) [UnscheduledEvent]
manipulateOutgoing t fs ues = do
  concat <$> forM ues act
  where
    act ue = do
      r <- random
      pure $ manipulateOutGoingEvent ue fs t r

-- echo "{\"tag\":\"ClientRequest''\",\"contents\":[\"CreateTest\",[{\"tag\":\"SInt\",\"contents\":0}]]}" | http POST :3005 && echo "{\"tag\":\"ClientRequest''\",\"contents\":[\"Start\",[]]}" | http POST :3005

pattern CreateTest tid cid = ClientRequest' "CreateTest" [SInt tid] cid

fakeScheduler :: RemoteRef -> Message -> Actor SchedulerState
fakeScheduler executorRef (CreateTest tid cid) = Actor $ do
  p <- asyncIO (IOQuery "SELECT agenda FROM test_info WHERE test_id = :tid" [":tid" := tid])
  q <- asyncIO (IOQuery "SELECT IFNULL(MAX(run_id), -1) + 1 FROM run_info WHERE test_id = :tid"
                [":tid" := tid])
  on p (\(IOResultR (IORows rs)) -> case parseRows rs of
           Nothing          -> clientResponse cid (InternalMessage "parse error" Null)
           Just [AgendaList es] -> do
             modify $ \s ->
               s { agenda = Agenda.fromList (map (\e -> (at e, e)) es)
                 , testId = Just tid
                 }
             clientResponse cid (InternalMessage (show es) Null))
  -- XXX: combine `on (p and q)` somehow? the current way we can respond to the
  -- client without having set the runId... Also this current way we can't
  -- really handle an error for the run id select?
  on q (\(IOResultR (IORows [[FInt rid]])) ->
           modify $ \s -> s { runId = Just rid })
  return (InternalMessage "ok" Null)
fakeScheduler executorRef (ClientRequest' "LoadTest" [SInt tid, SInt rid] cid) = Actor $ do
  p <- asyncIO (IOQuery "SELECT agenda FROM test_info WHERE test_id = :tid" [":tid" := tid])
  on p (\(IOResultR (IORows rs)) -> case parseRows rs of
           Nothing          -> clientResponse cid (InternalMessage "parse error" Null)
           Just [AgendaList es] -> do
             modify $ \s ->
               s { agenda = Agenda.fromList (map (\e -> (at e, e)) es)
                 , testId = Just tid
                 }
             clientResponse cid (InternalMessage (show es) Null))
  f <- asyncIO (IOQuery "SELECT faults FROM run_info WHERE test_id = :tid AND run_id = :rid" [":tid" := tid, ":rid" := rid])
  on f (\(IOResultR (IORows rs)) -> case parseRows rs of
           Nothing          -> clientResponse cid (InternalMessage "parse error" Null)
           Just [fs@Faults{}] -> do
             let (fState, fAgenda) = newFaultState fs
             modify $ \s ->
               s { faultState = fState
                 , runId = Just rid
                 , agenda = agenda s <> fAgenda
                 })
             -- clientResponse cid (InternalMessage (show fs))) -- hmm should we just do one response?
  return (InternalMessage "ok" Null)
fakeScheduler executorRef (ClientRequest' "Start" [] cid) =
  let
    step :: Free (ActorF SchedulerState) ()
    step = do
      sa <- modifys whatToDo
      case sa of
        Execute (t, ev) dropped
          | dropped -> do
              modify $ \s -> s { time        = t
                               , logicalTime = succLogicalTime (logicalTime s)
                               , steps       = succ (steps s)
                               }
              _lnow <- logicalTime <$> get
              -- XXX:
              -- emitEvent traceC clientC testId runId dropped lnow ae
              step
          | otherwise -> do
              -- XXX: if client request we need to add it to state
              modify $ \s -> s { time        = t
                               , logicalTime = succLogicalTime (logicalTime s)
                               , steps       = succ (steps s)
                               }
              s <- get
              p <- send executorRef (InternalMessage (kind ev)
                                     (toJSON (manipulateEvent ev (faultState s))))
              -- currentLogicalTime <- Time.currentLogicalClock timeC
              -- emitEvent traceC clientC testId runId dropped currentLogicalTime ae
              on p (\(InternalMessageR (InternalMessage "Events" args)) -> do
                       -- XXX: with some probability duplicate the event?
                       let Success (ExecutorResponse evs _) = fromJSON args
                           evs' = filter (not . isOk) evs
                           -- XXX: make it possible to change this value from failure spec:
                           wr = WithMean 20
                       agenda' <- scheduleAgenda t wr =<< manipulateOutgoing t (faultState s) evs'
                       modify $ \s -> s { agenda = agenda s `Agenda.union` agenda' }

                       -- (cr, entries) <- partitionOutEvent clientC currentLogicalTime events
                       -- resolveClientResponses testId runId runInfo timeC cr

                       step
                   )
              -- let ref = senderRef runInfo (to $ Agenda.theEvent ae)
              -- let ie = toInEvent testId runId currentLogicalTime ae
              -- events <- case Executor.kind ie of
              --   Executor.KEInternalMessage -> Executor.execute executorC ref ie
              --   Executor.KEClient -> Executor.execute executorC ref ie
              --   Executor.KETimer -> Executor.timer executorC ref ie
        Done -> do
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

          -- The NetworkTrace event also contains the following fields needed
          -- for jepsen_history:

          --     json_extract(data, '$.jepsen-type')    AS kind,
          --     json_extract(data, '$.jepsen-process') AS process
          --  , ntJepsenType :: Maybe String
          --  , ntJepsenProcess :: Maybe Int


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
                                               "}") Null)
        TimeoutClient ae now -> do
          -- Time.advanceTime timeC now Time.BumpLogical  -- should this really bump logical?
          -- lnow <- Time.currentLogicalClock timeC
          -- emitTimeout traceC clientC testId runId False lnow ae
          -- go
          undefined
        {-
        Tick now -> do
          Time.advanceTime timeC now Time.KeepLogical
          events <- forM (allRefs runInfo) $ \ ref -> Executor.tick executorC ref now
          let (cr, entries) = partitionOutEvent (sort $ concat events)
          resolveClientResponses testId runId runInfo timeC  cr
          scheduleEvents randomC agendaC timeC entries
          go
        -}
  in
    Actor $ do
      firstStep step
      return (InternalMessage "ok" Null)
  where
    firstStep step = do
      p <- send executorRef (InternalMessage "init" (object []))
      -- currentLogicalTime <- Time.currentLogicalClock timeC
      -- emitEvent traceC clientC testId runId dropped currentLogicalTime ae
      let k (InternalMessageR (InternalMessage "Events" args)) =
            let
              Success (ExecutorResponse evs _) = fromJSON args
            in do
              agenda' <- scheduleAgenda zeroTime NoRandom (filter (not . isOk) evs)
              modify $ \s -> s { agenda = agenda s `Agenda.union` agenda' }
              step
      on p k
fakeScheduler _ msg = error (show msg)

-- XXX: Avoid going to string, not sure if we should use bytestring or text though?
entryToData :: Int -> Int -> UTCTime -> Bool -> Timestamped LogEntry -> String
entryToData slt rlt rst d (Timestamped (LogSend _from _to (InternalMessage msg _args)) _logicalTimestamp _t)
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

data AgendaList = AgendaList [SchedulerEvent]

instance ParseRow AgendaList where
  -- XXX: Text -> ByteString -> JSON, seems unnecessary? We only need the `at`
  -- field for the heap priority, the rest could remain as a text and sent as
  -- such to the executor?
  parseRow [FText t] = case eitherDecodeStrict (Text.encodeUtf8 t) of
    Right es -> Just (AgendaList es)
    Left err -> error (show err)
  parseRow x         = error (show x)
