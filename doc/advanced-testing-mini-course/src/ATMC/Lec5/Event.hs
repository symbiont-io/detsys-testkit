module ATMC.Lec5.Event where

import Data.ByteString.Lazy (ByteString)

import ATMC.Lec5.Time
import ATMC.Lec5.StateMachine

------------------------------------------------------------------------

data Event
  = NetworkEventE NetworkEvent
  | TimerEventE   TimerEvent
  | CommandEventE CommandEvent
  deriving Show

data NetworkEvent = NetworkEvent NodeId (Input ByteString ByteString)
  deriving Show

data TimerEvent = TimerEvent NodeId Time
  deriving Show

getEventTime :: Event -> Time
getEventTime (TimerEventE   (TimerEvent   _nodeId time))  = time
getEventTime (NetworkEventE (NetworkEvent _nodeId input)) = getInputTime input
  where
    getInputTime :: Input request message -> Time
    getInputTime (ClientRequest   time _cid _req) = time
    getInputTime (InternalMessage time _nid _msg) = time

data CommandEvent = Exit
  deriving Show

isExitCommand :: Event -> Bool
isExitCommand (CommandEventE Exit) = True
isExitCommand _otherwise           = False
