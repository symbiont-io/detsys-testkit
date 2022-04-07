{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}

module ATMC.Lec5SimulationTestingV2 where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TBQueue
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Lazy (ByteString)
import Data.Functor (void)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text.Read (decimal)
import Data.Typeable
import GHC.Natural
import Network.HTTP.Client
import Network.HTTP.Types.Status
import Network.Wai hiding (requestBody)
import Network.Wai.Handler.Warp

------------------------------------------------------------------------

type Addr = Int

data Network = Network
  { nSend    :: Addr -> ByteString -> IO ()
  , nDeliver :: IO (Addr, ByteString)
  , nStart   :: IO ()
  }

pORT :: Int
pORT = 8050

qUEUE_SIZE :: Natural
qUEUE_SIZE = 4096

networkHttp :: IO Network
networkHttp = do
  incoming <- newTBQueueIO qUEUE_SIZE
  mgr      <- newManager defaultManagerSettings
  initReq  <- parseRequest ("http://localhost:" ++ show pORT)
  let sendReq = \addr msg ->
        initReq { method      = "POST"
                , path        = path initReq <> BS8.pack (show addr)
                , requestBody = RequestBodyLBS msg
                }
  return Network
    { nSend    = \addr msg -> void (httpLbs (sendReq addr msg) mgr) -- XXX: error handling
    , nDeliver = atomically (readTBQueue incoming)
    , nStart   = run pORT (app incoming)
    }

app :: TBQueue (Addr, ByteString) -> Application
app incoming req respond =
  case requestMethod req of
    "POST" -> case parseAddr of
                Nothing -> respond (responseLBS status400 [] "No address")
                Just addr -> do
                  reqBody <- consumeRequestBodyStrict req
                  atomically (writeTBQueue incoming (addr, reqBody))
                  respond (responseLBS status200 [] "")
    _otherwise -> respond (responseLBS status400 [] "Unsupported method")
  where
    parseAddr :: Maybe Addr
    parseAddr =
      case pathInfo req of
        [txt] -> case decimal txt of
          Right (ix, _rest) -> Just ix
          _otherwise -> Nothing
        _otherwise   -> Nothing

data Codec input output = Codec
  { cEncode :: output -> ByteString
  , cDecode :: ByteString -> input
  }

codecIdentity :: Codec ByteString ByteString
codecIdentity = Codec id id

data Envelope a = Envelope
  { eAddr :: Addr
  , eItem :: a
  }

data SM state input output = SM
  { smState :: state
  , smStep  :: state -> Envelope input -> (state, Envelope output)
  }

data SomeCodecSM = forall state input output. Typeable state =>
                   SomeCodecSM (Codec input output) (SM state input output)

type Topology = Map Addr SomeCodecSM

eventLoop :: Network -> Topology -> IO ()
eventLoop net topo0 = do
  withAsync (worker topo0) $ \a -> do
    link a
    nStart net
  where
    worker :: Topology -> IO ()
    worker topo = do
      (addr, msg) <- nDeliver net
      case Map.lookup addr topo of
        Nothing -> worker topo
        Just (SomeCodecSM codec (SM state step)) -> do
          let input            = cDecode codec msg
              (state', output) = step state (Envelope addr input)
          nSend net (eAddr output) (cEncode codec (eItem output))
          worker (updateState addr state' topo)

updateState :: Typeable s => Addr -> s -> Topology -> Topology
updateState addr s topo = Map.update (go s) addr topo
  where
    go :: Typeable s => s -> SomeCodecSM -> Maybe SomeCodecSM
    go state' (SomeCodecSM codec (SM _state step)) =
      case cast state' of
        Just state -> Just (SomeCodecSM codec (SM state step))
        Nothing    -> Nothing