{-# LANGUAGE ExistentialQuantification #-}
module StuntDouble.EventLoop where

import Data.Map (Map)
import Control.Exception
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TBQueue

import StuntDouble.Actor
import StuntDouble.Message
import StuntDouble.Reference
import StuntDouble.EventLoop.State
import StuntDouble.EventLoop.Event
import StuntDouble.EventLoop.RequestHandler

------------------------------------------------------------------------

newtype EventLoopRef = EventLoopRef
  { loopRefLoopState :: LoopState }

------------------------------------------------------------------------

initLoopState :: IO LoopState
initLoopState = do
  a <- newEmptyTMVarIO
  queue <- newTBQueueIO 128
  return (LoopState a queue undefined undefined undefined undefined)

makeEventLoop :: IO EventLoopRef
makeEventLoop = do
  loopState <- initLoopState
  aReqHandler <- async (handleRequests loopState)
  -- tid' <- forkIO $ forever $ undefined loopState
  a <- async (handleEvents loopState)
  atomically (putTMVar (loopStateAsync loopState) a)
  return (EventLoopRef loopState)

handleEvents :: LoopState -> IO ()
handleEvents ls = go
  where
    go = do
      e <- atomically (readTBQueue (loopStateQueue ls))
      handleEvent e ls
      go

handleEvent :: Event -> LoopState -> IO ()
handleEvent (Command c) ls = handleCommand c ls
handleEvent (Receive r) ls = handleReceive r ls

handleCommand :: Command -> LoopState -> IO ()
handleCommand (Spawn actor respVar) ls = do
  undefined
handleCommand (Invoke lr m respVar) ls = do
  -- actor <- findActor ls lr
  undefined
handleCommand (Send rr m) ls = do
  -- a <- async (makeHttpRequest (translateToUrl rr) (seralise m))
  -- atomically (modifyTVar (loopStateAsyncs ls) (a :))
  undefined
handleCommand Quit ls = do
  a <- atomically (takeTMVar (loopStateAsync ls))
  cancel a

handleReceive :: Receive -> LoopState -> IO ()
handleReceive (Request e) ls = do
  actor <- undefined -- findActor ls (envelopeReceiver e)
  runActor ls (actor (envelopeMessage e))

runActor :: LoopState -> Actor -> IO ()
runActor ls = undefined -- iterM go
  where
    go :: ActorF (IO a) -> IO a
    go (Call lref msg k) = do
      undefined
    go (RemoteCall rref msg k) = do
      undefined
    go (AsyncIO m k) = do
      a <- async m
      atomically (modifyTVar (loopStateIOAsyncs ls) (a :))
      k a
    go (Get k) =  do
      undefined
    go (Put state' k) = do
      undefined

quit :: EventLoopRef -> IO ()
quit r = atomically $
  writeTBQueue (loopStateQueue (loopRefLoopState r)) (Command Quit)

helper :: EventLoopRef -> (TMVar a -> Command) -> IO a
helper r cmd = atomically $ do
  respVar <- newEmptyTMVar
  writeTBQueue (loopStateQueue (loopRefLoopState r)) (Command (cmd respVar))
  takeTMVar respVar

spawn :: EventLoopRef -> (Message -> Actor) -> IO LocalRef
spawn r actor = helper r (Spawn actor)

invoke :: EventLoopRef -> LocalRef -> Message -> IO Message
invoke r lref msg = helper r (Invoke lref msg)

testActor :: Message -> Actor
testActor (Message "hi") = return (Now (Message "bye!"))

test :: IO ()
test = do
  r <- makeEventLoop
  lref <- spawn r testActor
  let msg = Message "hi"
  reply <- invoke r lref msg
  print reply
  quit r
