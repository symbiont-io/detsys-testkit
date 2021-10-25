{-# LANGUAGE NumericUnderscores #-}

module Main where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Monad
import Data.IORef
import Data.Int
import Data.Time
import System.Mem (performGC)
import Text.Printf

import Disruptor.ConsumerUnboxed
import Disruptor.Producer
import Disruptor.RingBuffer.SingleProducerUnboxed
import Disruptor.SequenceNumber
import StuntDouble.Histogram.SingleProducer
import StuntDouble.AtomicCounterPadded

------------------------------------------------------------------------

iTERATIONS :: Int64
iTERATIONS = 50_000_000

main :: IO ()
main = do
  n <- getNumCapabilities
  printf "%-25.25s%10d\n" "CPU capabilities" n
  let ringBufferCapacity = 1024 * 64
  rb <- newRingBuffer ringBufferCapacity
  -- histo <- newHistogram
  -- transactions <- newCounter 0
  consumerFinished <- newEmptyMVar

  let ep = EventProducer (const (go iTERATIONS)) ()
        where
          go :: Int64 -> IO ()
          go 0 = return ()
          go n = do
            mSnr <- tryNext rb
            case mSnr of
              Some snr -> do
                -- {-# SCC "transactions+1" #-} incrCounter_ 1 transactions
                set rb snr (1 :: Int)
                publish rb snr
                go (n - 1)
              None -> do
                yield -- NOTE: This seems to be needed in the unboxed case, but
                      -- not in the boxed one, why?
                go n

  let handler _s _n snr endOfBatch = do
        -- t' <- {-# SCC "transactions-1" #-} decrCounter 1 transactions
        -- measureInt_ t' histo
        when (endOfBatch && getSequenceNumber snr == iTERATIONS - 1) $
          putMVar consumerFinished ()
        return ()

  ec <- newEventConsumer rb handler () [] (Sleep 1)
  setGatingSequences rb [ecSequenceNumber ec]

  performGC
  start <- getCurrentTime
  withEventProducer ep $ \aep ->
    withEventConsumer ec $ \aec -> do
      () <- takeMVar consumerFinished
      end <- getCurrentTime
      cancel aep
      cancel aec
      end <- getCurrentTime
      printf "%-25.25s%10d\n"     "Total number of events" iTERATIONS
      printf "%-25.25s%10.2f s\n" "Duration" (realToFrac (diffUTCTime end start) :: Double)
      let throughput :: Double
          throughput = realToFrac iTERATIONS / realToFrac (diffUTCTime end start)
      printf "%-25.25s%10.2f events/s\n" "Throughput" throughput
      -- meanTransactions <- hmean histo
      -- printf "%-25.25s%10.2f\n" "Mean concurrent txs" meanTransactions
      -- Just maxTransactions <- percentile 100.0 histo
      -- printf "%-25.25s%10.2f\n" "Max concurrent txs" maxTransactions
      -- printf "%-25.25s%10.2f ns\n" "Latency" ((meanTransactions / throughput) * 1000000)
