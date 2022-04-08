module ATMC.Lec5.Time where

import Data.IORef
import Data.Time
import Data.Time.Calendar.OrdinalDate

import ATMC.Lec5.Options

------------------------------------------------------------------------

newtype Time = Time UTCTime
  deriving Show

data Clock = Clock
  { cGetCurrentTime :: IO Time
  , cSetCurrentTime :: Time -> IO ()
  }

realClock :: IO Clock
realClock = return Clock
  { cGetCurrentTime = Time <$> getCurrentTime
  , cSetCurrentTime = \_ -> return () -- Can't change the real clock.
  }

fakeClock :: Time -> IO Clock
fakeClock t0 = do
  ref <- newIORef t0
  return Clock
    { cGetCurrentTime = readIORef ref
    , cSetCurrentTime = writeIORef ref
    }

epoch :: Time
epoch = Time (UTCTime (fromOrdinalDate 1970 0) 0)

fakeClockEpoch :: IO Clock
fakeClockEpoch = fakeClock epoch

newClock :: Deployment -> IO Clock
newClock Production = realClock
newClock Simulation = fakeClockEpoch
