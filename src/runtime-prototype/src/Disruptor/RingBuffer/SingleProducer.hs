module Disruptor.RingBuffer.SingleProducer where

import Control.Exception (assert)
import Control.Monad (when)
import Data.Int (Int64)
import Data.Vector.Mutable (IOVector)
import qualified Data.Vector.Mutable as Vector
import Data.Bits (popCount)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)

import Disruptor.SequenceNumber

------------------------------------------------------------------------

data RingBuffer e = RingBuffer
  {
  -- | The capacity, or maximum amount of values, of the ring buffer.
    rbCapacity :: {-# UNPACK #-} !Int64
  -- | The cursor pointing to the head of the ring buffer.
  , rbCursor :: {-# UNPACK #-} !(IORef SequenceNumber)
  -- | The values of the ring buffer.
  , rbEvents :: {-# UNPACK #-} !(IOVector e)
  -- | References to the last consumers' sequence numbers, used in order to
  -- avoid wrapping the buffer and overwriting events that have not been
  -- consumed yet.
  , rbGatingSequences :: {-# UNPACK #-} !(IORef [IORef SequenceNumber])
  -- | Cached value of computing the last consumers' sequence numbers using the
  -- above references.
  , rbCachedGatingSequence :: {-# UNPACK #-} !(IORef SequenceNumber)
  }

newRingBuffer :: Int -> IO (RingBuffer e)
newRingBuffer capacity
  | capacity <= 0          =
      error "newRingBuffer: capacity must be greater than 0"
  | popCount capacity /= 1 =
      -- NOTE: The use of bitwise and (`.&.`) in `index` relies on this.
      error "newRingBuffer: capacity must be a power of 2"
  | otherwise              = do
      snr <- newIORef (-1)
      v   <- Vector.new capacity
      gs  <- newIORef []
      cgs <- newIORef (-1)
      return (RingBuffer (fromIntegral capacity) snr v gs cgs)
{-# INLINABLE newRingBuffer #-}

-- | The capacity, or maximum amount of values, of the ring buffer.
capacity :: RingBuffer e -> Int64
capacity = rbCapacity
{-# INLINE capacity #-}

getCursor :: RingBuffer e -> IO SequenceNumber
getCursor rb = readIORef (rbCursor rb)
{-# INLINE getCursor #-}

setGatingSequences :: RingBuffer e -> [IORef SequenceNumber] -> IO ()
setGatingSequences rb = writeIORef (rbGatingSequences rb)
{-# INLINE setGatingSequences #-}

getCachedGatingSequence :: RingBuffer e -> IO SequenceNumber
getCachedGatingSequence rb = readIORef (rbCachedGatingSequence rb)
{-# INLINE getCachedGatingSequence #-}

setCachedGatingSequence :: RingBuffer e -> SequenceNumber -> IO ()
setCachedGatingSequence rb = writeIORef (rbCachedGatingSequence rb)
{-# INLINE setCachedGatingSequence #-}

minimumSequence :: RingBuffer e -> IO SequenceNumber
minimumSequence rb = do
  cursorValue <- getCursor rb
  minimumSequence' (rbGatingSequences rb) cursorValue
{-# INLINE minimumSequence #-}

minimumSequence' :: IORef [IORef SequenceNumber] -> SequenceNumber -> IO SequenceNumber
minimumSequence' gatingSequences cursorValue = do
  snrs <- mapM readIORef =<< readIORef gatingSequences
  return (minimum (cursorValue : snrs))
{-# INLINE minimumSequence' #-}

-- | Currently available slots to write to.
size :: RingBuffer e -> IO Int64
size rb = do
  consumed <- minimumSequence rb
  produced <- getCursor rb
  return (capacity rb - fromIntegral (produced - consumed))
{-# INLINABLE size #-}

-- | Claim the next event in sequence for publishing.
next :: RingBuffer e -> IO SequenceNumber
next rb = nextBatch rb 1
{-# INLINE next #-}

-- | Claim the next `n` events in sequence for publishing. This is for batch
-- event producing. Returns the highest claimed sequence number, so using it
-- requires a bit of extra work, e.g.:
--
-- @
--     let n = 10
--     hi <- nextBatch rb n
--     let lo = hi - (n - 1)
--     mapM_ f [lo..hi]
--     publishBatch rb lo hi
-- @
--
nextBatch :: RingBuffer e -> Int -> IO SequenceNumber
nextBatch rb n = assert (n > 0 && fromIntegral n <= capacity rb) $ do
  current <- getCursor rb
  let nextSequence :: SequenceNumber
      nextSequence = current + fromIntegral n

      wrapPoint :: SequenceNumber
      wrapPoint = nextSequence - fromIntegral (capacity rb)

  writeIORef (rbCursor rb) nextSequence
  cachedGatingSequence <- getCachedGatingSequence rb

  when (wrapPoint > cachedGatingSequence || cachedGatingSequence > current) $
    waitForConsumers wrapPoint

  return nextSequence
  where
    waitForConsumers :: SequenceNumber -> IO ()
    waitForConsumers wrapPoint = go
      where
        go :: IO ()
        go = do
          gatingSequence <- minimumSequence rb
          if wrapPoint > gatingSequence
          then go
          else setCachedGatingSequence rb gatingSequence
{-# INLINE nextBatch #-}

-- Try to return the next sequence number to write to. If `Nothing` is returned,
-- then the last consumer has not yet processed the event we are about to
-- overwrite (due to the ring buffer wrapping around) -- the callee of `tryNext`
-- should apply back-pressure upstream if this happens.
tryNext :: RingBuffer e -> IO (Maybe SequenceNumber)
tryNext rb = tryNextBatch rb 1
{-# INLINE tryNext #-}

tryNextBatch :: RingBuffer e -> Int -> IO (Maybe SequenceNumber)
tryNextBatch rb n = assert (n > 0) $ do
  current <- getCursor rb
  let next = current + fromIntegral n
      wrapPoint = next - fromIntegral (capacity rb)
  cachedGatingSequence <- getCachedGatingSequence rb
  if (wrapPoint > cachedGatingSequence || cachedGatingSequence > current)
  then do
    minSequence <- minimumSequence' (rbGatingSequences rb) current
    setCachedGatingSequence rb minSequence
    if (wrapPoint > minSequence)
    then return Nothing
    else return (Just next)
  else return (Just next)
{-# INLINE tryNextBatch #-}

set :: RingBuffer e -> SequenceNumber -> e -> IO ()
set rb snr e = Vector.write (rbEvents rb) (index (rbCapacity rb) snr) e
{-# INLINE set #-}

publish :: RingBuffer e -> SequenceNumber -> IO ()
publish rb = writeIORef (rbCursor rb)
{-# INLINE publish #-}

publishBatch :: RingBuffer e -> SequenceNumber -> SequenceNumber -> IO ()
publishBatch rb _lo hi = writeIORef (rbCursor rb) hi
{-# INLINE publishBatch #-}

unsafeGet :: RingBuffer e -> SequenceNumber -> IO e
unsafeGet rb current = Vector.read (rbEvents rb) (index (capacity rb) current)
{-# INLINE unsafeGet #-}
