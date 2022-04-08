{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ATMC.Lec5.Network where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Concurrent.STM.TBQueue
import Control.Exception
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Lazy (ByteString)
import Data.Functor
import Data.Text.Read (decimal)
import Data.Typeable
import Network.HTTP.Client
import Network.HTTP.Types.Status
import Network.Wai hiding (requestBody)
import Network.Wai.Handler.Warp
import System.Timeout (timeout)

import ATMC.Lec5.Agenda
import ATMC.Lec5.AwaitingClients
import ATMC.Lec5.Options
import ATMC.Lec5.StateMachine
import ATMC.Lec5.Time

------------------------------------------------------------------------

pORT :: Int
pORT = 8050

data Network = Network
  { nRecv :: STM RawInput
  , nSend :: NodeId -> NodeId -> ByteString -> IO ()
  , nRun  :: IO ()
  }

realNetwork :: AwaitingClients -> Clock -> IO Network
realNetwork ac clock = do
  incoming <- newTBQueueIO 65536
  mgr      <- newManager defaultManagerSettings
  initReq  <- parseRequest ("http://localhost:" ++ show pORT)
  let sendReq = \fromNodeId toNodeId msg ->
        initReq { method      = "PUT"
                , path        = path initReq <> BS8.pack (show (unNodeId toNodeId))
                , requestBody = RequestBodyLBS msg
                }
      send from to msg = void (httpLbs (sendReq from to msg) mgr)
                        `catch` (\(e :: HttpException) ->
                                   putStrLn ("send failed, error: " ++ show e))
  return Network
    { nSend = send
    , nRecv = readTBQueue incoming
    , nRun  = run pORT (app ac clock incoming)
    }

app :: AwaitingClients -> Clock -> TBQueue RawInput -> Application
app awaiting clock incoming req respond =
  case requestMethod req of
    "POST" -> case parseNodeId of
                Nothing -> respond (responseLBS status400 [] "Missing receiver node id")
                Just toNodeId -> do
                  reqBody <- consumeRequestBodyStrict req
                  (fromClientId, resp) <- addAwaitingClient awaiting
                  time <- cGetCurrentTime clock
                  atomically
                    (writeTBQueue incoming
                      (RawInput toNodeId (ClientRequest time fromClientId reqBody)))
                  mBs <- timeout (60_000_000) (takeMVar resp) -- 60s
                  removeAwaitingClient awaiting fromClientId
                  case mBs of
                    Nothing -> do
                      putStrLn "Client response timed out..."
                      respond (responseLBS status500 [] "Timeout due to overload or bug")
                    Just bs -> respond (responseLBS status200 [] bs)
    "PUT" -> case parse2NodeIds of
               Nothing -> respond (responseLBS status400 [] "Missing sender/receiver node id")
               Just (fromNodeId, toNodeId) -> do
                  reqBody <- consumeRequestBodyStrict req
                  time <- cGetCurrentTime clock
                  atomically
                    (writeTBQueue incoming
                      (RawInput toNodeId (InternalMessage time fromNodeId reqBody)))
                  respond (responseLBS status200 [] "")

    _otherwise -> respond (responseLBS status400 [] "Unsupported method")
  where
    parseNodeId :: Maybe NodeId
    parseNodeId =
      case pathInfo req of
        [txt] -> case decimal txt of
          Right (nodeId, _rest) -> Just (NodeId nodeId)
          _otherwise -> Nothing
        _otherwise   -> Nothing

    parse2NodeIds :: Maybe (NodeId, NodeId)
    parse2NodeIds =
      case pathInfo req of
        [txt, txt'] -> case (decimal txt, decimal txt') of
          (Right (nodeId, _rest), Right (nodeId', _rest')) ->
            Just (NodeId nodeId, NodeId nodeId')
          _otherwise -> Nothing
        _otherwise   -> Nothing

fakeNetwork :: AwaitingClients -> Clock -> IO Network
fakeNetwork awaiting clock = do
  agenda <- newTVarIO emptyAgenda
  return Network
    { nRecv = recv agenda
    , nSend = send agenda
    , nRun  = return ()
    }
  where
    recv :: TVar (Agenda RawInput) -> STM RawInput
    recv agenda = do
      a <- readTVar agenda
      case pop a of
        Nothing -> retry
        Just ((_time, rawInput), a') -> do
          writeTVar agenda a'
          return rawInput

    send :: TVar (Agenda RawInput) -> NodeId -> NodeId -> ByteString -> IO ()
    send agenda from to msg = do
      now <- cGetCurrentTime clock
      -- XXX: need seed to generate random arrival time
      let arrivalTime = addTime 1 now
      atomically (modifyTVar' agenda
        (push (arrivalTime, RawInput to (InternalMessage arrivalTime from msg))))

newNetwork :: Deployment -> AwaitingClients -> Clock -> IO Network
newNetwork Production = realNetwork
newNetwork Simulation = fakeNetwork
