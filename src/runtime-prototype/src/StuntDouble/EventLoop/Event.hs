{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module StuntDouble.EventLoop.Event where

import Control.Concurrent.STM
import Control.Concurrent.Async

import StuntDouble.Actor
import StuntDouble.Actor.State
import StuntDouble.Message
import StuntDouble.Reference

------------------------------------------------------------------------

data Event
  = Command Command
  | Receive Envelope
  | AsyncIODone (Async IOResult) IOResult

eventName :: Event -> String
eventName (Command cmd) = "Command/" ++ commandName cmd
eventName (Receive e)   = "Receive/" ++ show e
eventName (AsyncIODone _a ioResult) = "AsyncIODone/" ++ show ioResult

data Command
  = Spawn (Message -> Actor) State (TMVar LocalRef)
  | Quit

commandName :: Command -> String
commandName Spawn {} = "Spawn"
commandName Quit  {} = "Quit"

newtype CorrelationId = CorrelationId Int
  deriving (Eq, Ord, Show, Read, Num, Enum)

getCorrelationId :: CorrelationId -> Int
getCorrelationId (CorrelationId i) = i

data EnvelopeKind = RequestKind | ResponseKind
  deriving (Eq, Show, Read)

data Envelope = Envelope
  { envelopeKind          :: EnvelopeKind
  , envelopeSender        :: RemoteRef
  , envelopeMessage       :: Message
  , envelopeReceiver      :: RemoteRef
  , envelopeCorrelationId :: CorrelationId
  }
  deriving (Eq, Show, Read)

replyEnvelope :: Envelope -> Message -> Envelope
replyEnvelope e msg
  | envelopeKind e == RequestKind =
    e { envelopeKind = ResponseKind
      , envelopeSender   = envelopeReceiver e
      , envelopeMessage  = msg
      , envelopeReceiver = envelopeSender e
      }
  | otherwise = error "reply: impossilbe: can't reply to a response..."

type EventLog = [LogEntry]

data LogEntry
  = LogInvoke RemoteRef LocalRef Message Message EventLoopName
  | LogSendStart RemoteRef RemoteRef Message CorrelationId EventLoopName
  | LogSendFinish CorrelationId Message EventLoopName
  | LogRequest RemoteRef RemoteRef Message Message EventLoopName
  | LogReceive RemoteRef RemoteRef Message CorrelationId EventLoopName
  | LogRequestStart RemoteRef RemoteRef Message CorrelationId EventLoopName
  | LogRequestFinish CorrelationId Message EventLoopName
  | LogComment String EventLoopName
  | LogAsyncIOFinish CorrelationId IOResult EventLoopName
  deriving (Eq, Show)

isComment :: LogEntry -> Bool
isComment LogComment {} = True
isComment _otherwise    = False
