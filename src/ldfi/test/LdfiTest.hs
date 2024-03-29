module LdfiTest where

import Ldfi
import Ldfi.FailureSpec
import Ldfi.Prop
import Ldfi.Sat
import Ldfi.Solver
import Ldfi.Storage
import Ldfi.Traces
import Test.HUnit hiding (Node)
import qualified Test.QuickCheck as QC

------------------------------------------------------------------------

emptyFailureSpec :: FailureSpec
emptyFailureSpec =
  FailureSpec
    { endOfFiniteFailures = 0,
      maxCrashes = 0,
      endOfTime = 0,
      numberOfFaultLimit = Nothing
    }

data WasSame = Same | NotSame String
  deriving (Show)

z3_same :: Formula -> Formula -> IO WasSame
z3_same l r = do
  sol <- z3Solve (Neg (l :<-> r))
  pure $ case sol of
    Solution assignment -> NotSame (show assignment)
    NoSolution -> Same

shouldBe :: Formula -> Formula -> Assertion
shouldBe actual expected = do
  result <- z3_same actual expected
  case result of
    Same -> pure ()
    NotSame modString -> assertFailure msg
      where
        msg =
          "expected: " ++ show expected ++ "\n but got: " ++ show actual
            ++ "\n model: "
            ++ modString

------------------------------------------------------------------------
-- Sanity checks for z3_same

unit_z3_same_eq :: Assertion
unit_z3_same_eq = do
  r <- z3_same (Var "A") (Var "A")
  case r of
    Same -> pure ()
    _ -> assertFailure msg
      where
        msg = "A was not equal to it self:\n" ++ show r

unit_z3_same_neq :: Assertion
unit_z3_same_neq = do
  r <- z3_same (Var "A") (Var "B")
  case r of
    NotSame _ -> pure ()
    _ -> assertFailure msg
      where
        msg = "A was equal to B:\n" ++ show r

------------------------------------------------------------------------

-- Peter Alvaro's cache example: "a frontend A depends on a service B
-- and a cache C. A typical cache hit might reveal edges like (A, B),
-- (A,C). but in the event of a cache miss, the trace will reveal the
-- computation that rehydrates the cache; eg (A, B), (A, R), (R, S1),
-- (R,S2). now the system has learned of a disjunction; for success, it
-- appears that we require A, B, and (C or (R,S1,S2)). after just a few
-- executions, LDFI is leveraging redundancy and not just injecting
-- faults arbitrarily. does that make sense? LDFI will never, e.g.,
-- suggest failing S1 or S2 or both without also suggesting failing C."
cacheTraces :: [Trace]
cacheTraces =
  [ [Event "A" 0 "B" 0, Event "A" 1 "C" 1],
    [Event "A" 0 "B" 0, Event "A" 1 "R" 1, Event "R" 2 "S1" 2, Event "R" 3 "S2" 3]
  ]

unit_cache_lineage :: Assertion
unit_cache_lineage =
  (fmap show $ simplify $ lineage cacheTraces)
    `shouldBe` (var "A" 0 "B" 0 :&& (var "A" 1 "C" 1 :|| And [var "A" 1 "R" 1, var "R" 2 "S1" 2, var "R" 3 "S2" 3]))
  where

dummyTestInformation :: TestInformation
dummyTestInformation = error "This testInformation will never be used."

unit_cacheFailures :: Assertion
unit_cacheFailures = do
  fs <- run (mockStorage cacheTraces) z3Solver dummyTestInformation emptyFailureSpec
  fs @?= [Omission ("A", "B") 0]

var :: Node -> Time -> Node -> Time -> Formula
var f ft t tt = Var (show $ EventVar (Event f ft t tt))

------------------------------------------------------------------------

-- Node A broadcasts to node B and C without retry. Node B getting the
-- message constitutes a successful outcome.
broadcast1Traces :: [Trace]
broadcast1Traces =
  [ [Event "A" 0 "B" 1, Event "A" 0 "C" 1],
    [Event "A" 0 "B" 1]
  ]

unit_broadcast1 :: Assertion
unit_broadcast1 =
  (fmap show $ simplify $ lineage broadcast1Traces)
    `shouldBe` (And [var "A" 0 "B" 1])

broadcastFailureSpec :: FailureSpec
broadcastFailureSpec =
  FailureSpec
    { endOfFiniteFailures = 3,
      maxCrashes = 1,
      endOfTime = 5,
      numberOfFaultLimit = Nothing
    }

-- TODO(stevan): This seems wrong, should be `Omission "A" "B" 1` or `Omission
-- "A" "C" 1`, can we make a variant of run that returns all possible models?
unit_broadcast1Run1 :: Assertion
unit_broadcast1Run1 = do
  fs <- run (mockStorage (take 1 broadcast1Traces)) z3Solver dummyTestInformation broadcastFailureSpec
  fs @?= [Omission ("A", "B") 1]

unit_broadcast1Run2 :: Assertion
unit_broadcast1Run2 = do
  fs <- run (mockStorage (take 2 broadcast1Traces)) z3Solver dummyTestInformation broadcastFailureSpec
  fs @?= [Omission ("A", "B") 1, Omission ("A", "C") 1] -- Minimal counterexample.

------------------------------------------------------------------------

-- Node A broadcasts to node B and C with retry. Node B getting the
-- message constitutes a successful outcome.
broadcast2Traces :: [Trace]
broadcast2Traces =
  [ [Event "A" 0 "B" 1, Event "A" 0 "C" 1],
    [Event "A" 0 "B" 1],
    [Event "A" 1 "B" 2, Event "A" 0 "C" 1],
    [Event "A" 3 "B" 4]
  ]

-- Lets assume that run 1 and 2 were the same as in broadcast1.
unit_broadcast2Run3 :: Assertion
unit_broadcast2Run3 = do
  fs <- run (mockStorage (take 3 broadcast2Traces)) z3Solver dummyTestInformation broadcastFailureSpec
  fs @?= [Crash "A" 1, Omission ("A", "B") 1]

unit_broadcast2Run4 :: Assertion
unit_broadcast2Run4 = do
  fs <- run (mockStorage (take 4 broadcast2Traces)) z3Solver dummyTestInformation broadcastFailureSpec
  fs
    @?= [ Crash "A" 1,
          Omission ("A", "B") 1
        ] -- Minimal counterexample.

------------------------------------------------------------------------
-- QuickCheck property

-- simplify gives a logical equivalent formula
prop_simplify_eq :: Formula -> QC.Property
prop_simplify_eq f =
  let simp_f = simplify1 f
   in QC.ioProperty $ do
        res <- z3_same f simp_f
        return $ case res of
          Same -> True
          _ -> False
