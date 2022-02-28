{-# LANGUAGE OverloadedStrings #-}

module Dumblog.Journal.FrontEnd where

import Control.Concurrent.MVar (MVar, putMVar)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import qualified Data.Char as Char
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Read as TextReader
import Network.HTTP.Types.Method
import Network.HTTP.Types.Status (status200, status400)
import qualified Network.Wai as Wai
import Network.Wai.Handler.Warp

import Journal (Journal)
import qualified Journal
import Journal.Types.AtomicCounter (AtomicCounter)
import qualified Journal.Types.AtomicCounter as AtomicCounter

import Dumblog.Journal.Blocker
import Dumblog.Journal.Codec
import Dumblog.Journal.Types

data FrontEndInfo = FrontEndInfo
  { sequenceNumber :: AtomicCounter
  , blockers :: Blocker (Either Response Response)
  }

httpFrontend :: Journal -> FrontEndInfo -> Wai.Application
httpFrontend journal (FrontEndInfo c blocker) req respond = do
  body <- Wai.strictRequestBody req
  key <- AtomicCounter.incrCounter 1 c
  let mmethod = case parseMethod $ Wai.requestMethod req of
        Left err -> Left $ LBS.fromStrict err
        Right GET -> case Wai.pathInfo req of
          [it] -> case TextReader.decimal it of
            Left err -> Left $ LBS8.pack err
            Right (i, t)
              | Text.null t -> Right $ Read i
              | otherwise -> Left $ "Couldn't parse `"
                 <> LBS.fromStrict (Text.encodeUtf8 it)
                 <> "` as an integer"
          _ -> Left "Path need to have transaction index"
        Right POST -> Right $ Write (LBS.toStrict body)
        _ -> Left $ "Unknown method type require GET/POST"
  case mmethod of
    Left err -> respond $ Wai.responseLBS status400 [] err
    Right cmd -> do
      res <- Journal.appendBS journal (encode $ Envelope key cmd)
      case res of
        Left err -> do
          respond $ Wai.responseLBS status400 [] "Rotation?"
        Right{} -> do
          resp <- blockUntil blocker key
          -- Journal.dumpJournal journal
          case resp of
            Left errMsg -> respond $ Wai.responseLBS status400 [] errMsg
            Right msg -> respond $ Wai.responseLBS status200 [] msg

runFrontEnd :: Port -> Journal -> FrontEndInfo -> Maybe (MVar ()) -> IO ()
runFrontEnd port journal feInfo mReady =
  runSettings settings (httpFrontend journal feInfo)
  where
    settings
      = setPort port
      $ maybe id (\ready -> setBeforeMainLoop (putMVar ready ())) mReady
      $ defaultSettings
