{-# LANGUAGE OverloadedStrings #-}

module Ldfi.Solver where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Map (Map)
import qualified Data.Map as Map

import Ldfi.Prop

------------------------------------------------------------------------
-- * Solver

data Solution = NoSolution | Solution (Map String Bool)
  deriving Show

marshal :: Solution -> ByteString
marshal NoSolution            = "{\"faults\": []}"
marshal (Solution assignment) =
  "{\"faults\":" `mappend` marshalList vars `mappend `"}"
  where
    vars = [ var | (var, true) <- Map.toList assignment, true ]

marshalList :: [String] -> ByteString
marshalList = BS.pack . show

data Solver m = Solver
  { solve :: Formula -> m Solution }
