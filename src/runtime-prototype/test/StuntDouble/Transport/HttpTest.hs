{-# LANGUAGE ScopedTypeVariables #-}

module StuntDouble.Transport.HttpTest where

import Control.Exception
import Control.Concurrent
import Test.HUnit

import StuntDouble.Transport.Http
import StuntDouble.Transport
import StuntDouble

------------------------------------------------------------------------

unit_transportHttp :: IO ()
unit_transportHttp = do
  let port = 3001
      url = "http://localhost:" ++ show port
  catch (do t <- httpTransport port
            let e = Envelope RequestKind (RemoteRef url 0) (InternalMessage "msg")
                             (RemoteRef url 1) 0 (LogicalTime (NodeName "x") 0)
            transportSend t e
            e' <- transportReceive t
            e' @?= Just e)
    (\(e :: SomeException) -> print e)
