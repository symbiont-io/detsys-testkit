{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ATMC.Lec5.StateMachineDSL where

import Control.Monad.Trans.Class
import Control.Monad.Trans.State
import Control.Monad.Trans.Writer
import GHC.Records.Compat

import ATMC.Lec5.StateMachine

------------------------------------------------------------------------

type SMM s req msg resp a = StateT s (Writer [Output resp msg]) a

runSMM :: SMM s req msg resp () -> s -> (((), s), [Output resp msg])
runSMM m s = runWriter (runStateT m s)

send :: NodeId -> msg -> SMM s req msg resp ()
send nid msg = lift (tell [InternalMessageOut nid msg])

reply :: ClientId -> resp -> SMM s req msg resp ()
reply cid resp = lift (tell [ClientResponse cid resp])

set :: forall f s a req msg resp proxy. HasField f s a
    => proxy f -> a -> SMM s req msg resp ()
set _ x = modify (\s -> setField @f s x)

update :: forall f s a req msg resp proxy. HasField f s a
       => proxy f -> (a -> a) -> SMM s req msg resp ()
update _ u = modify (\s -> setField @f s (u (getField @f s)))

data ExampleState = ExampleState
  { esInt :: Int
  }
  deriving Show

instance HasField "esInt" ExampleState Int where
  hasField (ExampleState i) = (ExampleState, i)

example :: SMM ExampleState req msg resp ()
example = do
  set    @"esInt" undefined 1
  update @"esInt" undefined (+2)
  update @"esInt" undefined (+3)

t = runSMM example (ExampleState 0)
