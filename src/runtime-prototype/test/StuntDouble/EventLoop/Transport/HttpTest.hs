{-# LANGUAGE ScopedTypeVariables #-}

module StuntDouble.EventLoop.Transport.HttpTest where

import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Test.HUnit

import StuntDouble.EventLoop.Transport.Http
import StuntDouble.EventLoop.Transport
import StuntDouble

------------------------------------------------------------------------

unit_httpSendReceive :: IO ()
unit_httpSendReceive = do
  let port = 3001
      url = "http://localhost:" ++ show port
  catch (do t <- httpTransport port
            let e = Envelope RequestKind (RemoteRef url 0) (Message "msg") (RemoteRef url 1) 0
            -- XXX: add better way to detect when http server is ready...
            threadDelay 100000
            a <- async (transportSend t e)
            e' <- transportReceive t
            cancel a
            e' @?= e)
    (\(e :: SomeException) -> print e)