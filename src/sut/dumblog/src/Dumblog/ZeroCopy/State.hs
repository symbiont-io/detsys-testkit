module Dumblog.ZeroCopy.State where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Int (Int64)
import Data.Vector.Mutable (IOVector)
import qualified Data.Vector.Mutable as Vector
import Data.Word (Word16, Word64)
import Network.Socket (Socket)
import Network.Socket.ByteString (sendAll)
import Network.Socket.SendFile.Handle (sendFile')
import System.IO (Handle, openFile, IOMode(ReadMode))

import Journal.Types (hEADER_LENGTH)
import Journal.Types.AtomicCounter

------------------------------------------------------------------------

data State = State
  { sLocations :: !(IOVector Location)
  , sIndex     :: !AtomicCounter
  , sFd        :: !Handle
  }

initState :: Int -> FilePath -> IO State
initState size fp
  = State
  <$> Vector.replicate size uninitialisedLocation
  <*> newCounter 0
  <*> openFile fp ReadMode

data Location = Location
  { lOffset :: !Word64
  , lLength :: !Word16
  }
  deriving Eq

uninitialisedLocation :: Location
uninitialisedLocation = Location 0 0

writeLocation :: State -> Int64 -> Location -> IO Int
writeLocation s offset loc = do
  ix <- getAndIncrCounter 1 (sIndex s)
  Vector.write (sLocations s) ix
    (loc { lOffset = fromIntegral (offset - 4096) + lOffset loc })
  return ix

readLocation :: State -> Int -> IO (Maybe Location)
readLocation s ix = do
  loc <- Vector.read (sLocations s) ix
  if loc == uninitialisedLocation
  then return Nothing
  else return (Just loc)

readSendfile :: State -> Socket -> Int -> IO ()
readSendfile s sock ix = do
  mLoc <- readLocation s ix
  case mLoc of
    Nothing  -> sendAll sock notFound
    Just loc -> do
      sendAll sock (httpHeader (lLength loc))
      _bytesSent <- sendFile' sock (sFd s)
                      (fromIntegral (lOffset loc) + fromIntegral hEADER_LENGTH)
                      (fromIntegral (lLength loc))
      return ()
  where
    notFound :: ByteString
    notFound = BS.pack "HTTP/1.0 404 Not Found\r\n\r\n"

    httpHeader :: Word16 -> ByteString
    httpHeader len =
      BS.pack "HTTP/1.0 200 OK\r\nContent-Length: " <> BS.pack (show len) <> BS.pack "\r\n\r\n"
