{-# LANGUAGE OverloadedStrings #-}
module FrontEnd where

import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import qualified Data.Char as Char
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Read as TextReader
import Network.HTTP.Types.Status (status200, status400)
import Network.HTTP.Types.Method
import qualified Network.Wai as Wai
import Network.Wai.Handler.Warp

import Journal (Journal)
import qualified Journal
import Journal.Types.AtomicCounter (AtomicCounter)
import qualified Journal.Types.AtomicCounter as AtomicCounter

import Blocker
import Codec
import Types

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
      Journal.appendBS journal (encode $ Envelope key cmd)
      resp <- blockUntil blocker key
      Journal.dumpJournal journal
      case resp of
        Left errMsg -> respond $ Wai.responseLBS status400 [] errMsg
        Right msg -> respond $ Wai.responseLBS status200 [] msg

runFrontEnd :: Int -> Journal -> FrontEndInfo -> IO ()
runFrontEnd port journal feInfo = run port (httpFrontend journal feInfo)
