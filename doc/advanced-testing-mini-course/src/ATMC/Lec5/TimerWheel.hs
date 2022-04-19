module ATMC.Lec5.TimerWheel where

import Control.Concurrent (threadDelay)
import Data.Time
import Data.Fixed
import Data.Foldable
import Data.IORef
import Data.Heap (Entry(Entry), Heap)
import qualified Data.Heap as Heap

import ATMC.Lec5.Time
import ATMC.Lec5.Event
import ATMC.Lec5.EventQueue
import ATMC.Lec5.StateMachine

------------------------------------------------------------------------

newtype TimerWheel = TimerWheel (IORef (Heap (Entry Time NodeId)))

newTimerWheel :: IO TimerWheel
newTimerWheel = do
  ref <- newIORef Heap.empty
  return (TimerWheel ref)

registerTimer :: TimerWheel -> Clock -> NodeId -> Pico -> IO ()
registerTimer (TimerWheel hr) clock nodeId secs = do
  now <- cGetCurrentTime clock
  let expires = addTime (secondsToNominalDiffTime secs) now
  atomicModifyIORef' hr (\h -> (Heap.insert (Entry expires nodeId) h, ()))

resetTimer :: TimerWheel -> Clock -> NodeId -> Pico -> IO ()
resetTimer (TimerWheel hr) clock nodeId secs = do
  now <- cGetCurrentTime clock
  let expires = addTime (secondsToNominalDiffTime secs) now
  atomicModifyIORef' hr (\h -> (Heap.map (go expires) h, ()))
    where
      go expires e@(Entry _expires nodeId')
        | nodeId' == nodeId = Entry expires nodeId
        | otherwise         = e

-- XXX: Possible future extension: if nothing has expired, sleep until either 1)
-- min element on heap expires, or 2) we get woken up by register/reset timer.
-- I.e. `Async.race (threadDelay minTime) (takeMVar wakeup)`.
expiredTimers :: TimerWheel -> Clock -> IO [(NodeId, Time)]
expiredTimers (TimerWheel hr) clock  = do
  now <- cGetCurrentTime clock
  atomicModifyIORef' hr (go now [] . toList)
    where
      go :: Time -> [(NodeId, Time)] -> [Entry Time NodeId]
        -> (Heap (Entry Time NodeId), [(NodeId, Time)])
      go _now acc [] = (Heap.empty, reverse acc)
      go  now acc (Entry t nodeId : es)
        | t <= now  = go now ((nodeId, t) : acc) es
        | otherwise = (Heap.fromList es, reverse acc)

runTimerManager :: TimerWheel -> Clock -> EventQueue -> IO ()
runTimerManager tw clock eventQueue = go
  where
    go = do
      tos <- expiredTimers tw clock
      mapM_ (eqEnqueue eventQueue . TimerEventE . uncurry TimerEvent) tos
      threadDelay 1000 -- 1 ms
      go