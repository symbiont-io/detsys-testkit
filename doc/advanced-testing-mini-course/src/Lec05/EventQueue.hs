module Lec05.EventQueue where

import Control.Concurrent.STM
import Data.IORef
import System.Timeout (timeout)

import Lec05.Agenda
import Lec05.Event
import Lec05.Time

------------------------------------------------------------------------

data DequeueTimeout
  = NoTimeout
  | Timeout Int        -- ^ Micro seconds.
            (IO Event) -- ^ Retry action.

data EventQueue = EventQueue
  { eqEnqueue :: Event -> IO ()
  , eqDequeue :: DequeueTimeout -> IO Event
  }

realEventQueue :: Clock -> IO EventQueue
realEventQueue _clock = do
  q <- newTQueueIO
  return EventQueue
    { eqEnqueue = atomically . writeTQueue q
    , eqDequeue = \dequeueTimeout -> case dequeueTimeout of
        NoTimeout -> atomically (readTQueue q)
        Timeout micros retry -> do
          mEvent <- timeout micros (atomically (readTQueue q))
          case mEvent of
            Nothing    -> retry
            Just event -> return event
    }

fakeEventQueue :: Agenda -> Clock -> IO EventQueue
fakeEventQueue a0 clock = do
  agenda <- newIORef a0
  return EventQueue
    { eqEnqueue = enqueue agenda
    , eqDequeue = dequeue agenda
    }
  where
    enqueue :: IORef Agenda -> Event -> IO ()
    enqueue agenda event = modifyIORef' agenda (push (getEventTime event, event))

    dequeue :: IORef Agenda -> DequeueTimeout -> IO Event
    dequeue agenda NoTimeout = do
      a <- readIORef agenda
      case pop a of
        Nothing -> return (CommandEventE Exit)
        Just ((_time, event), a') -> do
          writeIORef agenda a'
          return event
    dequeue agenda (Timeout micros retry) = do
      cModifyCurrentTime clock (addTimeMicros micros)
      retry
