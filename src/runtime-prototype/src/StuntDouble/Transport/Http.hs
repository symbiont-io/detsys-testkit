{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module StuntDouble.Transport.Http where

import qualified Data.HashMap.Strict as HashMap
import Data.Text (Text)
import Data.Heap (Heap)
import GHC.Generics (Generic)
import Data.Aeson
import Data.String
import Data.Aeson.Internal
import Control.Concurrent.Async
import Control.Concurrent.STM
import Data.ByteString.Char8 as BS
import Data.ByteString.Lazy as LBS
import Network.HTTP.Client
import Network.HTTP.Types.Status
import qualified Network.Wai as Wai
import Network.Wai.Handler.Warp

import StuntDouble.Envelope
import StuntDouble.Transport
import StuntDouble.Reference
import StuntDouble.Message
import StuntDouble.Codec

------------------------------------------------------------------------

httpTransport :: Port -> IO (Transport IO)
httpTransport port = do
  queue <- newTBQueueIO 128 -- XXX: when/how does this grow?
  readyTMVar <- newEmptyTMVarIO
  let settings = setPort port
               . setBeforeMainLoop (atomically (putTMVar readyTMVar ()))
               $ defaultSettings
  aServer <- async (runSettings settings (waiApp queue))
  aReady  <- async (atomically (takeTMVar readyTMVar))
  ok <- waitEither aServer aReady
  case ok of
    Left () -> error "httpTransport: impossible, server should not return"
    Right () -> do
      manager <- newManager defaultManagerSettings
      return Transport { transportSend = transportSend' manager
                       , transportReceive = atomically (tryReadTBQueue queue)
                       , transportShutdown = cancel aServer
                       }

transportSend' :: Manager -> Envelope -> IO ()
transportSend' manager e = do
  request <- envelopeToRequest e
  -- XXX: Instead of sending right away here, we could batch instead and only
  -- send ever 10 ms or whatever, we could also send concurrently (we would need
  -- to asynchronously take care of possible errors though).
  responseBody <$> httpNoBody request manager

envelopeToRequest :: Envelope -> IO Request
envelopeToRequest e = do

  let url :: String
      url = address (envelopeReceiver e)

      body :: RequestBody
      body = RequestBodyLBS (encodeJSONEnvelope e)

  initialRequest <- parseRequest url

  return initialRequest
           { method      = "POST"
           , requestBody = body
           }

waiApp :: TBQueue Envelope -> Wai.Application
waiApp queue req respond = do
  eEnvelope <- waiRequestToEnvelope req
  case eEnvelope of
    Left err -> do
      respond (Wai.responseLBS status500 [] ("Couldn't parse request: " <> fromString err))
    Right envelope -> do
      atomically (writeTBQueue queue envelope)
      respond (Wai.responseLBS status200 [] LBS.empty)

waiRequestToEnvelope :: Wai.Request -> IO (Either String Envelope)
waiRequestToEnvelope req = do
  body <- Wai.lazyRequestBody req
  return (decodeJSONEnvelope body)
