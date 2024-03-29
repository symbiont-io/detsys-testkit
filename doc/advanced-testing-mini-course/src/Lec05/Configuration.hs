{-# LANGUAGE ExistentialQuantification #-}

module Lec05.Configuration where

import Data.TreeDiff (ToExpr)
import Data.Typeable
import Data.Vector.Mutable (IOVector)
import qualified Data.Vector.Mutable as Vector

import Lec05.Codec
import Lec05.StateMachine

------------------------------------------------------------------------

newtype Configuration = Configuration (IOVector SomeCodecSM)

data SomeCodecSM = forall state request message response.
  ( Show state, Show request, Show message, Show response
  , ToExpr state
  , Typeable state, Typeable request, Typeable response
  ) => SomeCodecSM (Codec request message response)
                   (SM state request message response)

nrOfNodes :: Configuration -> Int
nrOfNodes (Configuration v) = Vector.length v

makeConfiguration :: [SomeCodecSM] -> IO Configuration
makeConfiguration sms = Configuration <$> Vector.generate (length sms) (sms !!)

lookupReceiver :: NodeId -> Configuration -> IO (Maybe SomeCodecSM)
lookupReceiver (NodeId nid) (Configuration v)
  | nid < Vector.length v = Just <$> Vector.read v nid
  | otherwise             = return Nothing

updateReceiverState :: Typeable state => NodeId -> state -> Configuration -> IO ()
updateReceiverState (NodeId nid) newState0 (Configuration v) =
  Vector.modify v (updateState newState0) nid
  where
    updateState :: Typeable state => state -> SomeCodecSM -> SomeCodecSM
    updateState newState' (SomeCodecSM codec (SM _oldState initF step timeout)) =
      case cast newState' of
        Just newState -> SomeCodecSM codec (SM newState initF step timeout)
        Nothing       -> error "updateReceiverState: state type mismatch"
