{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}

module Ldfi.Prop where

import Data.Set (Set)
import qualified Data.Set as Set
import qualified Test.QuickCheck as QC

------------------------------------------------------------------------

-- * Propositional logic formulae

infixr 3 :&&

infixr 2 :||

data FormulaF var
  = FormulaF var :&& FormulaF var
  | FormulaF var :|| FormulaF var
  | FormulaF var :+ FormulaF var
  | FormulaF var :-> FormulaF var
  | And [FormulaF var]
  | Or [FormulaF var]
  | Neg (FormulaF var)
  | FormulaF var :<-> FormulaF var
  | AtMost [var] Int
  | TT
  | FF
  | Var var
  deriving (Eq, Show, Foldable, Functor)

type Formula = FormulaF String

genFormula :: [v] -> Int -> QC.Gen (FormulaF v)
genFormula env 0 =
  QC.oneof
    [ pure TT,
      pure FF,
      Var <$> QC.elements env
    ]
genFormula env size =
  QC.oneof
    [ genFormula env 0,
      Neg <$> genFormula env (size - 1),
      QC.elements [(:&&), (:||), (:+), (:<->)] <*> genFormula env (size `div` 2) <*> genFormula env (size `div` 2),
      do
        n <- QC.choose (0, size `div` 2)
        QC.elements [And, Or] <*> QC.vectorOf n (genFormula env (size `div` 4))
    ]

instance QC.Arbitrary v => QC.Arbitrary (FormulaF v) where
  arbitrary = do
    env <- QC.listOf1 QC.arbitrary
    QC.sized (genFormula env)

getVars :: Ord var => FormulaF var -> Set var
getVars = foldMap Set.singleton

simplify1 :: FormulaF var -> FormulaF var
simplify1 (TT :&& r) = simplify1 r
simplify1 (l :&& r) = simplify1 l :&& simplify1 r
simplify1 (FF :|| r) = simplify1 r
simplify1 (_l :|| TT) = TT
simplify1 (l :|| r) = simplify1 l :|| simplify1 r
simplify1 (And []) = TT
simplify1 (And [f]) = f
simplify1 (And fs) = And (map simplify1 fs)
simplify1 (Or []) = FF
simplify1 (Or [f]) = f
simplify1 (Or fs) = Or (map simplify1 fs)
simplify1 (Neg f) = Neg (simplify1 f)
simplify1 (l :<-> r) = simplify1 l :<-> simplify1 r
simplify1 (l :-> r) = simplify1 l :-> simplify1 r
simplify1 (l :+ r) = simplify1 l :+ simplify1 r
simplify1 f@(AtMost {}) = f
simplify1 f@TT = f
simplify1 f@FF = f
simplify1 f@(Var _) = f

fixpoint :: Eq a => (a -> a) -> a -> a
fixpoint f x
  | f x == x = x
  | otherwise = fixpoint f (f x)

simplify :: Eq var => FormulaF var -> FormulaF var
simplify = fixpoint simplify1

makeVars :: Set var -> FormulaF var
makeVars = And . map Var . Set.toList
