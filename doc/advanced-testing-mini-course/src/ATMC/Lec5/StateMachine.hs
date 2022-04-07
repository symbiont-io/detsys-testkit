module ATMC.Lec5.StateMachine where

import Data.ByteString.Lazy (ByteString)

import ATMC.Lec5.Time

------------------------------------------------------------------------

newtype NodeId = NodeId { unNodeId :: Int }
  deriving (Eq, Ord, Show)

newtype ClientId = ClientId { unClientId :: Int }
  deriving (Eq, Ord, Show)

data SM state request message response = SM
  { smState :: state
  , smStep  :: Input request message -> state -> ([Output response message], state)
  }

data Input request message
  = ClientRequest Time ClientId request
  | InternalMessage Time NodeId message

data Output response message
  = ClientResponse ClientId response
  | InternalMessageOut NodeId message
  deriving (Eq, Show)

data RawInput = RawInput NodeId (Input ByteString ByteString)

inputTime :: Input request message -> Time
inputTime (ClientRequest   time _cid _req) = time
inputTime (InternalMessage time _nid _msg) = time

rawInputTime :: RawInput -> Time
rawInputTime (RawInput _to input) = inputTime input
