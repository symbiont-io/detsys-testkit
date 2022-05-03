{-# LANGUAGE MultiWayIf #-}
module Lec05.ViewstampReplication.Machine where

import Control.Monad (forM_, unless, when)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Time.Clock (secondsToNominalDiffTime)
import GHC.Stack (HasCallStack)

import Lec05.Agenda
import Lec05.Codec
import Lec05.Event
import Lec05.StateMachine
import Lec05.StateMachineDSL
import Lec05.Time (addTime, epoch)
import Lec05.ViewstampReplication.Message
import Lec05.ViewstampReplication.State

{-
Following the `Viewstamped Replication Revisited`
  by Barbara Liskov and James Cowling
https://pmg.csail.mit.edu/papers/vr-revisited.pdf
-}

type VR s o r a = SMM (VRState s o r) (VRMessage o) (VRResponse r) a

tODO :: HasCallStack => a
tODO = error "Not implemented yet"

isPrimary :: VR s o r Bool
isPrimary = do
  ViewNumber cVn <- use currentViewNumber
  nodes <- use (configuration.to length)
  rn <- use replicaNumber
  return (rn == cVn `mod` nodes)

checkIsPrimary :: VR s o r ()
checkIsPrimary = guardM isPrimary

checkIsBackup :: ViewNumber -> VR s o r ()
checkIsBackup msgVN = do
  guardM (not <$> isPrimary)
  {-
Replicas only process normal protocol mes-
sages containing a view-number that matches the view-
number they know. If the sender is behind, the receiver
drops the message. If the sender is ahead, the replica
performs a state transfer§
  -}
  cVn <- use currentViewNumber
  if
    | cVn == msgVN -> return ()
    | cVn >  msgVN -> ereturn -- drop the message
    | cVn <  msgVN -> initStateTransfer

broadCastReplicas :: VRMessage o -> VR s o r ()
broadCastReplicas msg = do
  nodes <- use configuration
  ViewNumber cVn <- use currentViewNumber
  forM_ (zip [0..] nodes) $ \ (i, node) -> do
    unless (i == cVn `mod` length nodes) $ send node msg

broadCastOtherReplicas :: VRMessage o -> VR s o r ()
broadCastOtherReplicas msg = do
  nodes <- use configuration
  ViewNumber cVn <- use currentViewNumber
  me <- use replicaNumber
  forM_ (zip [0..] nodes) $ \ (i, node) -> do
    unless (i == cVn `mod` length nodes || i == me) $ send node msg

sendPrimary :: VRMessage o -> VR s o r ()
sendPrimary msg = do
  nodes <- use configuration
  ViewNumber cVn <- use currentViewNumber
  send (nodes !! (cVn `mod` length nodes)) msg

addPrepareOk :: OpNumber -> NodeId -> VR s o r Int
addPrepareOk n i = do
  s <- primaryPrepareOk.at n <%= Just . maybe (Set.singleton i) (Set.insert i)
  return (maybe 0 Set.size s)

isQuorum :: Int -> VR s o r Bool
isQuorum x = do
  n <- use (configuration.to length)
  -- `f` is the largest number s.t 2f+1<=n
  let f = (n - 1) `div` 2
  return (f <= x)

findClientInfoForOp :: OpNumber -> VR s o r (ClientId, RequestNumber)
findClientInfoForOp on = use $
  clientTable.to (Map.filter (\cs -> copNumber cs == on)).to Map.findMin.to (fmap requestNumber)

generateNonce :: VR s o r Nonce
generateNonce = Nonce <$> random

initStateTransfer :: VR s o r ()
initStateTransfer = do
  {- 4.3 Recovery
1. The recovering replica, i, sends a 〈RECOVERY i, x〉
message to all other replicas, where x is a nonce.
-}
  guardM $ use (currentStatus.to (== Normal))
  currentStatus .= Recovering
  nonce <- generateNonce
  broadCastOtherReplicas $ Recovery nonce
  ereturn

executeReplicatedMachine :: o -> VR s o r r
executeReplicatedMachine op = do
  cs <- use currentState
  sm <- use (stateMachine.to runReplicated)
  let (result, cs') = sm cs op
  currentState .= cs'
  return result

{- -- When we get ticks --
6. Normally the primary informs backups about the
commit when it sends the next PREPARE message;
this is the purpose of the commit-number in the
PREPARE message. However, if the primary does
not receive a new client request in a timely way, it
instead informs the backups of the latest commit by
sending them a 〈COMMIT v, k〉 message, where k
is commit-number (note that in this case commit-
number = op-number).
-}

machine :: Input (VRRequest o) (VRMessage o) -> VR s o r ()
machine (ClientRequest time c (VRRequest op s)) = do
  {-
1. The client sends a 〈REQUEST op, c, s〉 message to
the primary, where op is the operation (with its ar-
guments) the client wants to run, c is the client-id,
and s is the request-number assigned to the request.
  -}
  checkIsPrimary
  {-
2. When the primary receives the request, it compares
the request-number in the request with the informa-
tion in the client table. If the request-number s isn’t
bigger than the information in the table it drops the
request, but it will re-send the response if the re-
quest is the most recent one from this client and it
has already been executed.
  -}
  clientStatus <- use (clientTable.at c)
  case clientStatus of
    Nothing -> return ()
    Just cs -> do
      guard (requestNumber cs <= s)
      case cs of
        Completed s' v r vn
          | s' == s -> do
              -- should check that it has been executed?
              respond c (VRReply vn s r)
              ereturn
          | otherwise -> return ()
        InFlight{} -> return ()
  {-
3. The primary advances op-number, adds the request
to the end of the log, and updates the information
for this client in the client-table to contain the new
request number, s. Then it sends a 〈PREPARE v, m,
n, k〉 message to the other replicas, where v is the
current view-number, m is the message it received
from the client, n is the op-number it assigned to
the request, and k is the commit-number.
  -}
  opNumber += 1
  cOp <- use opNumber
  theLog %= (|> op)
  clientTable.at c .= Just (InFlight s cOp)
  v <- use currentViewNumber
  k <- use commitNumber
  broadCastReplicas $ Prepare v (InternalClientMessage op c s) cOp k
machine (InternalMessage time from iMsg) = case iMsg of
  Prepare v m n k -> do
    checkIsBackup v
    {-
4. Backups process PREPARE messages in order: a
backup won’t accept a prepare with op-number n
until it has entries for all earlier requests in its log.
When a backup i receives a PREPARE message, it
waits until it has entries in its log for all earlier re-
quests (doing state transfer if necessary to get the
missing information). Then it increments its op-
number, adds the request to the end of its log, up-
dates the client’s information in the client-table, and
sends a 〈PREPAREOK v, n, i〉 message to the pri-
mary to indicate that this operation and all earlier
ones have prepared locally.
    -}
    -- also look at step 7.
    myK <- use opNumber
    -- i <- use replicaNumber
    when (succ myK /= n) $ do
      -- We haven't processed earlier messages
      -- should start state transfer.
      -- TODO: for now we just drop
      ereturn
    opNumber += 1
    theLog %= (|> (m^.operation))
    clientTable.at (m^.clientId) .= Just (InFlight (m^.clientRequestNumber) n)
    sendPrimary $ PrepareOk v n {- i -} -- we don't need to add i since
                                        -- event-loop will add it automatically
  PrepareOk v n -> do
    let i = from
    checkIsPrimary
    {-
5. The primary waits for f PREPAREOK messages
from different backups; at this point it considers
the operation (and all earlier ones) to be commit-
ted. Then, after it has executed all earlier operations
(those assigned smaller op-numbers), the primary
executes the operation by making an up-call to the
service code, and increments its commit-number.
Then it sends a 〈REPLY v, s, x〉 message to the
client; here v is the view-number, s is the number
the client provided in the request, and x is the result
of the up-call. The primary also updates the client’s
entry in the client-table to contain the result.
    -}
    let cn = let OpNumber x = n in CommitNumber x
    guardM $ use (commitNumber.to (== pred cn))
    howMany <- addPrepareOk n from
    isQ <- isQuorum howMany
    if isQ
      then do
        l <- use theLog
        case logLookup n l of
          Nothing -> do
            -- shouldn't happen, we get a confirmation but don't remember the op
            ereturn
          Just op -> do
            result <- executeReplicatedMachine op
            commitNumber .= cn
            (clientId, requestNumber) <- findClientInfoForOp n
            respond clientId (VRReply v requestNumber result)
      else ereturn
  Commit v k -> do
    checkIsBackup v
    {-
7. When a backup learns of a commit, it waits un-
til it has the request in its log (which may require
state transfer) and until it has executed all earlier
operations. Then it executes the operation by per-
forming the up-call to the service code, increments
its commit-number, updates the client’s entry in the
client-table, but does not send the reply to the client.
    -}
    tODO
  Recovery x -> do
    let i = from
    {- 4.3 Recovery
2. A replica j replies to a RECOVERY message only
when its status is normal. In this case the replica
sends a 〈RECOVERYRESPONSE v, x, l, n, k, j〉 mes-
sage to the recovering replica, where v is its view-
number and x is the nonce in the RECOVERY mes-
sage. If j is the primary of its view, l is its log, n is
its op-number, and k is the commit-number; other-
wise these values are nil.
    -}
    guardM $ use (currentStatus.to (== Normal))
    v <- use currentViewNumber
    l <- use theLog
    j <- use replicaNumber
    isP <- isPrimary
    resp <- case isP of
      True -> FromPrimary <$> {- n -} use opNumber <*> {- k -} use commitNumber
      False -> pure FromReplica
    send i $ RecoveryResponse v x l resp j
  RecoveryResponse v x l resp j -> do
    {- 4.3 Recovery
3. The recovering replica waits to receive at least f +
1 RECOVERYRESPONSE messages from different
replicas, all containing the nonce it sent in its RE-
COVERY message, including one from the primary
of the latest view it learns of in these messages.
Then it updates its state using the information from
the primary, changes its status to normal, and the
recovery protocol is complete.
-}
    tODO

sm :: [NodeId] -> NodeId
  -> s -> ReplicatedStateMachine s o r
  -> SM (VRState s o r) (VRRequest o) (VRMessage o) (VRResponse r)
sm otherNodes me iState iSM = SM (initState otherNodes me iState iSM) (\i s g -> runSMM (machine i) s g) noTimeouts

--------------------------------------------------------------------------------
-- For testing
--------------------------------------------------------------------------------

vrCodec :: (Read m, Show m, Show r) => Codec (VRRequest m) (VRMessage m) (VRResponse r)
vrCodec = showReadCodec

agenda :: Agenda
agenda = makeAgenda
  [(t0, NetworkEventE (NetworkEvent (NodeId 0) (ClientRequest t0 (ClientId 0) req1)))
  ,(t1, NetworkEventE (NetworkEvent (NodeId 0) (ClientRequest t1 (ClientId 0) req2)))
  ]
  where
    t0 = epoch
    t1 = addTime (secondsToNominalDiffTime 20) t0
    req1 = encShow $ VRRequest "first" 0
    req2 = encShow $ VRRequest "second" 1