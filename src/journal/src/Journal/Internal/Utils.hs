{-# LANGUAGE MagicHash #-}

module Journal.Internal.Utils
  ( module Journal.Internal.Utils
  , module Assert)
  where

import Control.Exception (bracket)
import Data.Bits ((.|.))
import Data.Int (Int32, Int64)
import Foreign.Marshal.Alloc (callocBytes, free)
import GHC.Int (Int(I#), Int32(I32#), Int64(I64#))
import GHC.Word (Word32(W32#), Word64(W64#))
import GHC.Stack (HasCallStack)
import System.Directory (canonicalizePath, getTemporaryDirectory)
import System.IO (Handle, hClose, openTempFile)
import System.Posix.Files (ownerReadMode, ownerWriteMode)
import System.Posix.IO
       ( OpenMode(ReadWrite)
       , closeFd
       , defaultFileFlags
       , fdWriteBuf
       , openFd
       )
import System.Posix.Types (Fd)

import Assert
import Journal.Internal.FileAllocate

------------------------------------------------------------------------

withRWFd :: FilePath -> (Fd -> IO a) -> IO a
withRWFd fp k =
  bracket
    (openFd fp ReadWrite (Just (ownerReadMode .|. ownerWriteMode)) defaultFileFlags)
    closeFd
    k

int2Int32 :: Int -> Int32
int2Int32 (I# i#) =
  assert (fromIntegral (minBound :: Int32) <= I64# i#
          && I64# i# <= fromIntegral (maxBound :: Int32))
    (I32# i#)

int322Int :: Int32 -> Int
int322Int (I32# i#) =
  assert (fromIntegral (minBound :: Int) <= I64# i#
          && I64# i# <= fromIntegral (maxBound :: Int))
    (I# i#)

int2Int64 :: Int -> Int64
int2Int64 (I# i#) =
  assert ((minBound :: Int64) <= I64# i#
          && I64# i# <= (maxBound :: Int64))
    (I64# i#)

int642Int :: Int64 -> Int
int642Int i@(I64# i#) =
  assert (fromIntegral (minBound :: Int) <= i
          && i <= fromIntegral (maxBound :: Int))
    (I# i#)

word322Int :: Word32 -> Int
word322Int w@(W32# w#) = assert (W64# w# <= fromIntegral (maxBound :: Int)) (fromIntegral w)

int322Int64 :: Int32 -> Int64
int322Int64 (I32# i#) = I64# i#

fallocate :: FilePath -> Int -> IO ()
fallocate fp len = do
  withRWFd fp $ \fd -> do
    fileAllocate fd 0 (fromIntegral len)
    -- NOTE: `fileAllocate` only allocates the space it doesn't zero it,
    -- unlike `fallocate(1)`, so we do that next.
    bracket (callocBytes len) free $ \zeroesPtr -> do
      bytesWritten <- fdWriteBuf fd zeroesPtr (fromIntegral len)
      assertM (fromIntegral bytesWritten == len)

withTempFile :: String -> (FilePath -> Handle -> IO a) -> IO a
withTempFile name k = do
  tmp <- canonicalizePath =<< getTemporaryDirectory
  bracket (openTempFile tmp name) (\(_fp, h) -> hClose h) (uncurry k)
