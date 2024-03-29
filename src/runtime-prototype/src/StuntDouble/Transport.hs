module StuntDouble.Transport where

import StuntDouble.Envelope

------------------------------------------------------------------------

data TransportKind = NamedPipe FilePath | NamedPipeCodec FilePath | Http Int | HttpSync | Stm | UnixDomainSocket FilePath

data Transport m = Transport
  { transportSend     :: Envelope -> m ()
  , transportReceive  :: m (Maybe Envelope)
  , transportShutdown :: m ()
  }
