{-# LANGUAGE DeriveGeneric #-}
module Types where

import Data.Binary (Binary)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import GHC.Generics (Generic)

data Command
  = Write ByteString
  | Read Int
  deriving Generic

instance Binary Command where

type Response = LBS.ByteString