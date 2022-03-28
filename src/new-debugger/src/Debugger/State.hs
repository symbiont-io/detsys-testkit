{-# LANGUAGE DeriveGeneric #-}
module Debugger.State where

import Data.Aeson
import Data.Int
import GHC.Generics (Generic)
import Data.Vector (Vector)
import qualified Data.Vector as Vector

import Debugger.SequenceDia (Arrow(..), generate)

data DebEvent = DebEvent
  { from :: String
  , to :: String
  , event :: String
  , receivedLogical :: Int
  -- , receivedSimulated :: Time
  , message :: String
  } deriving (Generic, Show)

instance FromJSON DebEvent
instance ToJSON DebEvent

data InstanceState = InstanceState
 { isState :: String -- Should probably be per reactor
 , isCurrentEvent :: DebEvent
 , isRunningVersion :: Int64
 , isSeqDia :: Int -> String -- the current height
 , isLogs :: [String]
 , isSent :: [DebEvent]
 }

data InstanceStateRepr = InstanceStateRepr
  { state :: String
  , currentEvent :: DebEvent
  , runningVersion :: Int64
  , logs :: [String]
  , sent :: [DebEvent]
  } deriving Generic

instance FromJSON InstanceStateRepr

instance ToJSON InstanceStateRepr

toArrowDE :: DebEvent -> Arrow String
toArrowDE de = Arrow
  { aFrom = from de
  , aTo = to de
  , aAt = receivedLogical de
  , aMessage = event de
  }

toArrowIS :: InstanceStateRepr -> [Arrow String]
toArrowIS is = toArrowDE (currentEvent is) : map toArrowDE' (sent is)
  where
    -- we don't want to select the sent messages
    toArrowDE' d = toArrowDE d{receivedLogical = -1}

fromRepr :: Vector InstanceStateRepr -> Vector InstanceState
fromRepr xs = Vector.imap repr xs
  where
    arrows = concatMap toArrowIS $ Vector.toList xs
    repr :: Int -> InstanceStateRepr -> InstanceState
    repr currentIx i = InstanceState
      { isState = state i
      , isCurrentEvent = currentEvent i
      , isRunningVersion = runningVersion i
      , isSeqDia = generate arrows currentIx
      , isLogs = logs i
      , isSent = sent i
      }
