{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Dumblog.Journal.FrontEnd where

import Control.Concurrent.MVar (MVar, putMVar)
import Data.Binary (encode)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Int (Int64)
import Data.Text.Read (decimal)
import Network.HTTP.Types.Status (status200, status400, status404)
import qualified Network.Wai as Wai
import Network.Wai.Handler.Warp
import System.Timeout (timeout)

import Journal.Internal.Metrics (incrCounter)
import qualified Journal.MP as Journal
import Journal.Types (Journal)

import Dumblog.Common.Metrics
import Dumblog.Journal.Blocker
import Dumblog.Journal.Codec
import Dumblog.Journal.Types

------------------------------------------------------------------------

data FrontEndInfo = FrontEndInfo
  { blockers :: Blocker ClientResponse
  , currentVersion :: Int64
  }

httpFrontend :: Journal -> DumblogMetrics -> FrontEndInfo -> Wai.Application
httpFrontend journal metrics (FrontEndInfo blocker cVersion) req respond = do
  case Wai.requestMethod req of
    "GET" -> do
      case parseIndex of
        Left err -> do
          incrCounter metrics ErrorsEncountered 1
          respond (Wai.responseLBS status400 [] err)
        Right ix -> appendInput (ClientRequest (Read ix))
    "POST" -> do
      reqBody <- Wai.consumeRequestBodyStrict req
      appendInput (ClientRequest (Write reqBody))
    "PUT" -> do
      case parseIndex of
        Left err -> do
          incrCounter metrics ErrorsEncountered 1
          respond (Wai.responseLBS status400 [] err)
        Right ix  -> do
          reqBody <- Wai.consumeRequestBodyStrict req
          if not (LBS8.null reqBody)
          then appendInput (InternalMessageIn (Backup ix reqBody))
          else appendInput (InternalMessageIn (Ack ix))

    _otherwise -> do
      incrCounter metrics ErrorsEncountered 1
      respond (Wai.responseLBS status400 [] "Invalid method")
  where
    parseIndex :: Either ByteString Int
    parseIndex =
      case Wai.pathInfo req of
        [txt] -> case decimal txt of
          Right (ix, _rest) -> Right ix
          _otherwise -> Left (LBS8.pack "parseIndex: GET /:ix, :ix isn't an integer")
        _otherwise   -> Left (LBS8.pack "parseIndex: GET /:ix, :ix missing")

    appendInput :: Input -> IO Wai.ResponseReceived
    appendInput input = do
      key <- newKey blocker
      !arrivalTime <- getCurrentNanosSinceEpoch
      let bs = encode (Envelope (sequenceNumber key) input cVersion arrivalTime)
          success = do
            incrCounter metrics QueueDepth 1
            blockRespond key
          failure err = do
            cancel blocker key
            incrCounter metrics ErrorsEncountered 1
            respond $ Wai.responseLBS status400 [] (LBS8.pack (show err))
      retryAppendBS bs success failure
      where
        blockRespond key = do
          mResp <- timeout (30*1000*1000) (blockUntil key)
          -- Journal.dumpJournal journal
          case mResp of
            Nothing -> do
              cancel blocker key
              incrCounter metrics ErrorsEncountered 1
              respond $ Wai.responseLBS status400 [] "MVar timeout"
            Just (Error errMsg) -> do
              incrCounter metrics ErrorsEncountered 1
              respond $ Wai.responseLBS status400 [] errMsg
            Just NotFound -> do
              incrCounter metrics ErrorsEncountered 1
              respond $ Wai.responseLBS status404 [] "Not found"
            Just (OK msg) -> respond $ Wai.responseLBS status200 [] msg

        retryAppendBS bs success failure = do
          res <- Journal.appendLBS journal bs
          case res of
            Left err -> do
              putStrLn ("httpFrontend, append error: " ++ show err)
              res' <- Journal.appendLBS journal bs
              case res' of
                Left err' -> do
                  putStrLn ("httpFrontend, append error 2: " ++ show err')
                  failure err'
                Right () -> success
            Right () -> success

runFrontEnd :: Port -> Journal -> DumblogMetrics -> FrontEndInfo -> Maybe (MVar ()) -> IO ()
runFrontEnd port journal metrics feInfo mReady =
  runSettings settings (httpFrontend journal metrics feInfo)
  where
    settings
      = setPort port
      $ setOnOpen  (\_addr -> incrCounter metrics CurrentNumberTransactions 1 >> return True)
      $ setOnClose (\_addr -> incrCounter metrics CurrentNumberTransactions (-1))
                     -- >> putStrLn ("closing: " ++ show addr))
      -- $ setLogger (\req status _mSize ->
      --                 when (status /= status200) $ do
      --                   putStrLn ("warp, request: " ++ show req)
      --                   putStrLn ("warp, status: "  ++ show status)
      --                   print =<< Wai.strictRequestBody req)
      $ setBeforeMainLoop (putStrLn ("Running on port " ++ show port) >> maybe (pure ()) (\ready -> putMVar ready ()) mReady)
      $ defaultSettings
