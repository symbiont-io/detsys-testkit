module Dumblog.ZeroCopy.State where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Int (Int64)
import Data.Vector.Mutable (IOVector)
import qualified Data.Vector.Mutable as Vector
import Data.Word (Word16, Word64)
import Network.Socket (Socket)
import Network.Socket.ByteString (sendAll)
import System.Posix.IO (OpenMode(ReadOnly), defaultFileFlags, openFd)
import System.Posix.Types (Fd)

import Dumblog.ZeroCopy.Sendfile
import Journal.Types (hEADER_LENGTH)
import Journal.Types.AtomicCounter

------------------------------------------------------------------------

data State = State
  { sLocations :: !(IOVector Location)
  , sIndex     :: !AtomicCounter
  , sFd        :: !Fd
  }

initState :: Int -> FilePath -> IO State
initState size fp
  = State
  <$> Vector.new size
  <*> newCounter 0
  <*> openFd fp ReadOnly Nothing defaultFileFlags

data Location = Location
  { lOffset :: !Word64
  , lLength :: !Word16
  }

writeLocation :: State -> Int64 -> Location -> IO Int
writeLocation s offset loc = do
  ix <- getAndIncrCounter 1 (sIndex s)
  Vector.write (sLocations s) ix
    (loc { lOffset = fromIntegral (offset - 4096) + lOffset loc })
  return ix

readLocation :: State -> Int -> IO Location
readLocation s ix = Vector.read (sLocations s) ix

readSendfile :: State -> Socket -> Int -> IO ()
readSendfile s sock ix = do
  loc <- readLocation s ix
  sendAll sock (httpHeader (lLength loc))
  _bytesSent <- sendfile sock (sFd s)
                  (fromIntegral (lOffset loc) + fromIntegral hEADER_LENGTH)
                  (fromIntegral (lLength loc))
  return ()

httpHeader :: Word16 -> ByteString
httpHeader len =
  BS.pack "HTTP/1.0 200 OK\r\nContent-Length: " <> BS.pack (show len) <> BS.pack "\r\n\r\n"
