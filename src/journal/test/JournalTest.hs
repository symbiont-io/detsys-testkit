{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedStrings #-}

module JournalTest where

import Control.Arrow ((&&&))
import Control.Exception (IOException, catch, displayException)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Builder as BS
import Data.Monoid (Sum(Sum))
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import System.Directory
       (canonicalizePath, getTemporaryDirectory, removeFile)
import System.IO (openTempFile)
import System.Timeout (timeout)
import Test.QuickCheck
import Test.QuickCheck.Instances.ByteString ()
import Test.QuickCheck.Monadic
import Test.Tasty.HUnit (Assertion, assertBool)

import Journal
import Journal.Internal
import Journal.Internal.Utils hiding (assert)

------------------------------------------------------------------------

data FakeJournal' a = FakeJournal
  { fjJournal :: Vector a
  , fjIndex   :: Int
  }
  deriving (Show, Functor)

type FakeJournal = FakeJournal' ByteString

prettyFakeJournal :: FakeJournal -> String
prettyFakeJournal = show . fmap (prettyRunLenEnc . encodeRunLength)

startJournalFake :: FakeJournal
startJournalFake = FakeJournal Vector.empty 0

appendBSFake :: ByteString -> FakeJournal -> (FakeJournal, Either AppendError ())
appendBSFake bs fj@(FakeJournal jour ix)
  | unreadBytes jour ix < limit = (FakeJournal (Vector.snoc jour bs) ix, Right ())
  | otherwise                   = (fj, Left BackPressure)
  where
    termLen = oTermBufferLength testOptions

    limit = termLen `div` 2

    unreadBytes :: Vector ByteString -> Int -> Int
    unreadBytes bss ix = sum [ BS.length bs
                             | bs <- map (bss Vector.!) [ix..Vector.length bss - 1]
                             ]
                       + padding 0 0 (Vector.toList (Vector.map BS.length bss))
      where
        padding :: Int -> Int -> [Int] -> Int
        padding acc pad []       = pad
        padding acc pad (l : ls)
          | acc + l + hEADER_LENGTH > termLen = padding acc (pad + (termLen - acc)) ls
          | otherwise                         = padding (acc + l + hEADER_LENGTH) pad ls


readJournalFake :: FakeJournal -> (FakeJournal, Maybe ByteString)
readJournalFake fj@(FakeJournal jour ix) =
  (FakeJournal jour (ix + 1), Just (jour Vector.! ix))

------------------------------------------------------------------------

data Command
  = AppendBS [(Int, Char)] -- Run length encoded bytestring.
  -- Tee
  -- AppendRecv
  | ReadJournal
  -- SaveSnapshot
  -- TruncateAfterSnapshot
  -- LoadSnapshot
  -- Replay
  | DumpJournal
  deriving Show

constructorString :: Command -> String
constructorString AppendBS {} = "AppendBS"
constructorString ReadJournal = "ReadJournal"
constructorString DumpJournal = "DumpJournal"

prettyCommand :: Command -> String
prettyCommand = show

prettyCommands :: [Command] -> String
prettyCommands = concat . go ["["] . map prettyCommand
  where
    go :: [String] -> [String] -> [String]
    go acc []       = reverse ("]" : acc)
    go acc [s]      = reverse ("]" : s : acc)
    go acc (s : ss) = go (", " : s : acc) ss

encodeRunLength :: ByteString -> [(Int, Char)]
encodeRunLength = map (BS.length &&& BS.head) . BS.group

decodeRunLength :: [(Int, Char)] -> ByteString
decodeRunLength = go mempty
  where
    go :: BS.Builder -> [(Int, Char)] -> ByteString
    go acc []             = LBS.toStrict (BS.toLazyByteString acc)
    go acc ((n, c) : ncs) = go (acc <> BS.byteString (BS.replicate n c)) ncs

prop_runLengthEncoding :: ByteString -> Property
prop_runLengthEncoding bs = bs === decodeRunLength (encodeRunLength bs)

prop_runLengthEncoding' :: Property
prop_runLengthEncoding' = forAll genRunLenEncoding $ \rle ->
  rle === encodeRunLength (decodeRunLength rle)

prettyRunLenEnc :: [(Int, Char)] -> String
prettyRunLenEnc ncs0 = case ncs0 of
  []           -> ""
  [(n, c)]     -> go n c
  (n, c) : ncs -> go n c ++ " " ++ prettyRunLenEnc ncs
  where
    go 1 c = [ c ]
    go n c = show n ++ "x" ++ [ c ]

data Response
  = Result (Either AppendError ())
  | ByteString (Maybe ByteString)
  | IOException IOException
  deriving Eq

prettyResponse :: Response -> String
prettyResponse (Result eu) = "Result (" ++ show eu ++ ")"
prettyResponse (ByteString (Just bs)) =
  "ByteString \"" ++ prettyRunLenEnc (encodeRunLength bs) ++ "\""
prettyResponse (ByteString Nothing) =
  "ByteString Nothing"
prettyResponse (IOException e) = "IOException " ++ displayException e

type Model = FakeJournal

-- If there's nothing new to read, then don't generate reads (because they are
-- blocking) and don't append empty bytestrings.
precondition :: Model -> Command -> Bool
precondition m ReadJournal    = Vector.length (fjJournal m) /= fjIndex m
precondition m (AppendBS rle) = let bs = decodeRunLength rle in
  not (BS.null bs) && BS.length bs + hEADER_LENGTH < oTermBufferLength testOptions `div` 2
precondition m DumpJournal = True

step :: Command -> Model -> (Model, Response)
step (AppendBS rle) m = Result <$> appendBSFake (decodeRunLength rle) m
step ReadJournal    m = ByteString <$> readJournalFake m
step DumpJournal    m = (m, Result (Right ()))

exec :: Command -> Journal -> IO Response
exec (AppendBS rle) j = do
  let bs = decodeRunLength rle
  eu <- appendBS j bs
  case eu of
    Left Rotation     -> Result <$> appendBS j bs
    Left BackPressure -> return (Result (Left BackPressure))
    Right ()          -> return (Result (Right ()))
exec ReadJournal   j = ByteString <$> readJournal j
exec DumpJournal   j = Result . Right <$> dumpJournal j

genRunLenEncoding :: Gen [(Int, Char)]
genRunLenEncoding = sized $ \n -> do
  len <- elements [ max 1 n -- Disallow n == 0.
                  , maxLen, maxLen - 1]
  chr <- elements ['A'..'Z']
  return [(len, chr)]
  where
    maxLen = (oTermBufferLength testOptions - hEADER_LENGTH - fOOTER_LENGTH) `div` 2

genCommand :: Gen Command
genCommand = frequency
  [ (1, AppendBS <$> genRunLenEncoding)
  , (1, pure ReadJournal)
  ]

genCommands :: Model -> Gen [Command]
genCommands m0 = sized (go m0)
  where
    go :: Model -> Int -> Gen [Command]
    go _m 0 = return []
    go m  n = do
      cmd <- genCommand `suchThat` precondition m
      cmds <- go (fst (step cmd m)) (n - 1)
      return (cmd : cmds)

shrinkCommand :: Command -> [Command]
shrinkCommand ReadJournal    = []
shrinkCommand (AppendBS rle) =
  [ AppendBS rle'
  | rle' <- shrinkList (\(i, c) -> [ (i', c) | i' <- shrink i ]) rle
  , not (null rle')
  ]

shrinkCommands :: Model -> [Command] -> [[Command]]
shrinkCommands m = filter (validProgram m) . shrinkList shrinkCommand

validProgram :: Model -> [Command] -> Bool
validProgram = go True
  where
    go False _m _cmds       = False
    go valid _m []          = valid
    go valid m (cmd : cmds) = go (precondition m cmd) (fst (step cmd m)) cmds

testOptions :: Options
testOptions = defaultOptions

prop_journal :: Property
prop_journal =
  let m = startJournalFake in
  forAllShrinkShow (genCommands m) (shrinkCommands m) prettyCommands $ \cmds -> monadicIO $ do
    -- run (putStrLn ("Generated commands: " ++ show cmds))
    tmp <- run (canonicalizePath =<< getTemporaryDirectory)
    (fp, h) <- run (openTempFile tmp "JournalTest")
    run (allocateJournal fp testOptions)
    j <- run (startJournal fp testOptions)
    monitor (tabulate "Commands" (map constructorString cmds))
    monitor (whenFail (dumpJournal j))
    (result, hist) <- go cmds m j []
    -- run (uncurry stopJournal j)
    -- monitorStats (stats (zip cmds hist))
    run (removeFile fp)
    return result
    where
      go :: [Command] -> Model -> Journal -> [Response] -> PropertyM IO (Bool, [Response])
      go []          _m _j hist = return (True, reverse hist)
      go (cmd : cmds) m  j hist = do
        let (m', resp) = step cmd m
        resp' <- run (exec cmd j `catch` (return . IOException))
        assertWithFail (resp == resp') $
          prettyResponse resp ++ " /= " ++ prettyResponse resp'
        go cmds m' j (resp : hist)

      assertWithFail :: Monad m => Bool -> String -> PropertyM m ()
      assertWithFail condition msg = do
        unless condition $
          monitor (counterexample ("Failed: " ++ msg))
        assert condition

-- XXX: Get this straight from the metrics of the journal instead?
  {-
data Stats = Stats
  { sBytesWritten :: Int
  , sRotations    :: Int
  }
  deriving Show

stats :: [(Command, Response)] -> Stats
stats hist = Stats
  { sBytesWritten = totalAppended
  -- XXX: doesn't account for footers...
  , sRotations    = totalAppended `div` oTermBufferLength testOptions
  }
  where
    Sum totalAppended =
      foldMap (\(cmd, _resp) ->
                 case cmd of
                   AppendBS bs -> Sum (hEADER_LENGTH + BS.length bs)
                   _otherwise  -> mempty) hist

monitorStats :: Monad m => Stats -> PropertyM m ()
monitorStats stats
  = monitor
  $ collect ("Bytes written: " <> show (sBytesWritten stats))
  . collect ("Rotations: "     <> show (sRotations stats))
-}

runCommands :: [Command] -> IO Bool
runCommands cmds = do
  let m = startJournalFake
  withTempFile "runCommands" $ \fp _handle -> do
    allocateJournal fp testOptions
    j <- startJournal fp testOptions
    putStrLn ""
    b <- go m j cmds []
    dumpJournal j
    return b
  where
    go :: Model -> Journal -> [Command] -> [(Command, Response)] -> IO Bool
    go m j [] _hist = putStrLn "\nSuccess!" >> return True
    go m j (cmd : cmds) hist = do
      let (m', resp) = step cmd m
      putStrLn (prettyFakeJournal m)
      putStrLn ""
      putStrLn ("    == " ++ prettyCommand cmd ++ " ==> " ++ prettyResponse resp)
      putStrLn ""
      if null cmds
      then putStrLn (prettyFakeJournal m')
      else return ()
      resp' <- exec cmd j `catch` (return . IOException)
      -- is <- checkForInconsistencies (fst j)
      if resp == resp' -- && null is
      then go m' j cmds ((cmd, resp) : hist)
      else do
        putStrLn ""
        when (resp /= resp') $
          putStrLn ("Failed: " ++ prettyResponse resp ++ " /= " ++ prettyResponse resp')
        -- when (not (null is)) $
        --   putStrLn ("Inconsistencies: " ++ inconsistenciesString is)
        putStrLn ""
        putStrLn "Journal dump:"
        dumpJournal j
        -- print (stats (reverse hist))
        return False

------------------------------------------------------------------------

-- XXX: make sure all these unit tests are part of the coverage...

unit_bug0 :: Assertion
unit_bug0 = assertProgram ""
  [ AppendBS [(2, 'E')]
  , AppendBS [(32752, 'O')]
  ]

unit_bug1 :: Assertion
unit_bug1 = assertProgram ""
  [ AppendBS [(32756, 'O')]
  , AppendBS [(32756, 'G')]
  ]

unit_bug11 :: Assertion
unit_bug11 = assertProgram ""
  [ AppendBS [(32756, 'O')]
  , ReadJournal
  , AppendBS [(32756, 'G')]
  , ReadJournal
  , AppendBS [(32756, 'K')]
  , DumpJournal
  , ReadJournal
  , AppendBS [(32756, 'J')]
  ]

unit_bug2 :: Assertion
unit_bug2 = assertProgram ""
  [ AppendBS [(7,'N')]
  , ReadJournal
  , AppendBS [(32756,'N')]
  , ReadJournal
  , AppendBS [(32756,'W')]
  , AppendBS [(32756,'Q')]
  ]
  -- limit = termBufferLength / 2 - hEADER_LENGTH = 65536 / 2 - 6 = 32762

unit_bug3 :: Assertion
unit_bug3 = assertProgram ""
  [AppendBS [(1, 'A')], AppendBS [(32755,'Q')], AppendBS [(1,'D')]]

{-
nit_bug0 :: Assertion
nit_bug0 = assertProgram "read after rotation"
  [ AppendBS "AAAAAAAAAAAAAAAAA"
  , AppendBS "BBBBBBBBBBBBBBBB"
  , ReadJournal
  , ReadJournal
  , AppendBS "CCCCCCCCCCCCCCCCC"
  , ReadJournal
  , AppendBS "DDDDDDDDDDDDDDDD"
  , ReadJournal
  , AppendBS "EEEEEEEEEEEEEEEE"
  , ReadJournal
  , AppendBS "FFFFFFFFFFFFFFFF"
  , ReadJournal
  ]

nit_bug1 :: Assertion
nit_bug1 = assertProgram "two rotations"
  [ AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  , AppendBS "XXXXXXXXXXXXXXXXXXXX"
  ]

nit_bug2 :: Assertion
nit_bug2 = assertProgram "stuck reading"
  [ AppendBS "OOOOOOOOOOOOO"
  , ReadJournal
  , AppendBS "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" -- 116 + 6 = 122 bytes
  , ReadJournal
  , AppendBS "UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUU" -- 116 + 6 = 122 bytes
  , ReadJournal
  ]

nit_bug3 :: Assertion
nit_bug3 = assertProgram "two rotations reading side"
  [ AppendBS "M"
  , AppendBS "RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR" -- 110 + 6 = 116 bytes
  , AppendBS "L"
  , ReadJournal
  , ReadJournal
  ]
  -}

------------------------------------------------------------------------

assertProgram :: String -> [Command] -> Assertion
assertProgram msg cmds = do
  b <- runCommands cmds
  assertBool msg b
