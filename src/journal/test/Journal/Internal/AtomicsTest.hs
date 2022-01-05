module Journal.Internal.AtomicsTest where

import Foreign
import Data.Word
import Control.Concurrent
import Control.Concurrent.Async
import Test.Tasty.HUnit (Assertion, assertEqual, assertBool)

import Journal.Internal.Atomics

------------------------------------------------------------------------

unit_atomic :: Assertion
unit_atomic = do
  capa <- getNumCapabilities
  assertBool "unit_atomic: -threaded needs to be passed" (capa > 1)
  let n = 10000
      c = 6
  alloca $ \ptr -> do
    poke ptr 0
    replicateConcurrently_ c (worker ptr n)
    result <- peek ptr
    assertEqual "unit_atomic" result (fromIntegral (c * n))
  where
    worker :: Ptr Word16 -> Int -> IO ()
    worker ptr = go
      where
        go 0 = return ()
        go n = do
          _ <- fetchAddWord16Ptr ptr 1
          go (n - 1)
