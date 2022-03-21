{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Plutarch.Test.Property.HaskEquiv (
  -- * The main property
  prop_haskEquiv,
  Equality (..),
  Totality (..),
  NP ((:*), Nil), -- Re-exports from sop-core for building Generator arguments

  -- * For writing helper functions using `prop_haskEquiv`
  LamArgs,
  HaskEquiv,

  -- * Useful properties
  prop_leftInverse,

  -- * Underlying equality tests
  testDataEq,
  testPEq,
) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad.IO.Class (liftIO)
import Data.SOP (NP (Nil, (:*)))
import Data.Text (Text)
import Hedgehog (Gen, Property, PropertyT, annotate, annotateShow, assert, forAll, property, (===))

import Plutarch (ClosedTerm, compile)
import Plutarch.Evaluate (EvalError, evalScript)
import Plutarch.Prelude
import Plutarch.Test.Property.Marshal (Marshal (marshal))

import Plutus.V1.Ledger.Scripts (Script (Script, unScript))
import PlutusCore.Evaluation.Machine.ExBudget (ExBudget)

-- | The nature of equality between two Plutarch terms.
data Equality
  = OnPEq
  | OnPData
  | OnBoth
  deriving stock (Eq, Show, Ord)

-- | Whether a function is total or partial.
data Totality
  = TotalFun
  | PartialFun
  deriving stock (Eq, Show, Ord)

{- |
  Class of pairs of Plutarch and Haskell types that are semantically
  equivalent, upto the given equality and totality.
-}
class HaskEquiv (e :: Equality) (t :: Totality) h p args where
  -- | Test that `hf` and `pf` are equal when applied on the given arguments.
  haskEquiv :: h -> ClosedTerm p -> NP Gen args -> PropertyT IO ()

-- | Argument types for a Haskell function (empty if a term value)
type family LamArgs f :: [Type] where
  LamArgs (a -> b) = a ': LamArgs b
  LamArgs _ = '[]

-- For lambda terms, generate the first argument and delegate.
instance
  (Show ha, Marshal ha pa, HaskEquiv e t hb pb (LamArgs hb), LamArgs (ha -> hb) ~ args) =>
  HaskEquiv e t (ha -> hb) (pa :--> pb) args
  where
  haskEquiv hf pf (a :* as) = do
    x <- forAll a
    haskEquiv @e @t (hf x) (pf # marshal x) as

instance (PIsData p, Marshal h p) => HaskEquiv 'OnPData 'TotalFun h p '[] where
  haskEquiv h p Nil = testDataEq h p

instance (PEq p, Marshal h p) => HaskEquiv 'OnPEq 'TotalFun h p '[] where
  haskEquiv h p Nil = testPEq (marshal h) p

instance
  ( PEq p
  , PIsData p
  , Marshal h p
  , HaskEquiv 'OnPEq 'TotalFun h p '[]
  , HaskEquiv 'OnPData 'TotalFun h p '[]
  ) =>
  HaskEquiv 'OnBoth 'TotalFun h p '[]
  where
  haskEquiv h p Nil = do
    haskEquiv @( 'OnPEq) @( 'TotalFun) h p Nil
    haskEquiv @( 'OnPData) @( 'TotalFun) h p Nil

instance
  (PIsData p, Marshal h p, HaskEquiv eq 'TotalFun h p '[]) =>
  HaskEquiv eq 'PartialFun h p '[]
  where
  haskEquiv h p Nil = testPartial (\h' p' -> haskEquiv @eq @( 'TotalFun) h' p' Nil) h p

{- |
  The given Plutarch term is equivalent to the given Haskell type upto the given
  equality and totality.

  Generator arguments must be non-empty if the term is a lambda. This function
  must always be called using `TypeApplications` specifying the first two
  type variables.

  Example:

  >>> prop_haskEquiv
    @'OnPEq
    @'TotalFun
    (reverse :: [Integer] -> [Integer])
    preverse
    (genList integerGen :* Nil)
-}
prop_haskEquiv ::
  forall (e :: Equality) (t :: Totality) h p.
  HaskEquiv e t h p (LamArgs h) =>
  h ->
  ClosedTerm p ->
  NP Gen (LamArgs h) ->
  Property
prop_haskEquiv h p = do
  property . haskEquiv @e @t h p

testDataEq :: (PIsData a, Marshal h a) => h -> ClosedTerm a -> PropertyT IO ()
testDataEq x y =
  pshouldBe (pdata $ marshal x) (pdata y)

testPartial :: (h -> ClosedTerm p -> PropertyT IO ()) -> h -> ClosedTerm p -> PropertyT IO ()
testPartial baseTest h p =
  liftIO (try $ evaluate h) >>= \case
    Left (_ :: SomeException) ->
      case run p of
        (Left _, _, _) -> assert True
        (Right _, _, _) -> do
          annotate "plutarch didn't fail but haskell did"
          assert False
    Right _ -> baseTest h p

testPEq :: PEq a => ClosedTerm a -> ClosedTerm a -> PropertyT IO ()
testPEq x y =
  -- Evaluate the terms once so we can annotate them individually.
  -- Then, evaluate `x #== y`.
  case (run x, run y) of
    ((Right (Script x'), _, _), (Right (Script y'), _, _)) -> do
      annotateShow x'
      annotateShow y'
      pshouldBe (pcon PTrue) (x #== y)
    _ -> assert False

-- | Like `Plutarch.Test.pshouldBe` but in Hedgehog property monad.
pshouldBe :: ClosedTerm a -> ClosedTerm a -> PropertyT IO ()
pshouldBe x y =
  -- testing equality of Scott encoded types
  -- this way is generally prone to false errors
  -- hence this function not being directly exposed
  case (run x, run y) of
    ((Right script1, _, trace1), (Right script2, _, trace2)) -> do
      annotateShow trace1
      annotateShow trace2
      annotateShow $ unScript script1
      annotateShow $ unScript script2
      trace1 === trace2
      script1 === script2
    _ -> assert False

run :: ClosedTerm h -> (Either EvalError Script, ExBudget, [Text])
run t = evalScript $ compile t

prop_leftInverse ::
  forall e t p p' h.
  ( LamArgs h ~ '[]
  , HaskEquiv e t (h -> h) (p :--> p) '[h]
  , Show h
  , Marshal h p
  ) =>
  ClosedTerm (p' :--> p) ->
  ClosedTerm (p :--> p') ->
  Gen h ->
  Property
prop_leftInverse l r arg =
  prop_haskEquiv @e @t (id @h) (plam $ \x -> l #$ r # x) (arg :* Nil)
