{-
Copyright 2015 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module Test.SlamData.Property.Workspace.Deck.Model
  ( ArbDeck
  , runArbDeck
  , check
  ) where

import SlamData.Prelude

import Data.Array (zipWith)

import SlamData.Workspace.Deck.Model as Model

import Test.StrongCheck (QC, Result(..), class Arbitrary, arbitrary, quickCheck)
import Test.SlamData.Property.Workspace.Card.Model (runArbCard, checkCardEquality)
import Test.SlamData.Property.Workspace.Card.CardId (runArbCardId)
import Data.Time (Milliseconds(..))

newtype ArbDeck = ArbDeck Model.Deck

runArbDeck ∷ ArbDeck → Model.Deck
runArbDeck (ArbDeck m) = m

newtype ArbMilliseconds = ArbMilliseconds Milliseconds

runArbMilliseconds ∷ ArbMilliseconds → Milliseconds
runArbMilliseconds (ArbMilliseconds ms) = ms

instance arbitraryArbMilliseconds ∷ Arbitrary ArbMilliseconds where
  arbitrary = ArbMilliseconds <$> Milliseconds <$> arbitrary

instance arbitraryArbWorkspace ∷ Arbitrary ArbDeck where
  arbitrary = do
    cards ← map runArbCard <$> arbitrary
    parent ← map (bimap id runArbCardId) <$> arbitrary
    mirror ← arbitrary
    name ← arbitrary
    createdAt ← map (map runArbMilliseconds) arbitrary
    pure $ ArbDeck { cards, parent, mirror, name, createdAt }

check ∷ QC Unit
check = quickCheck $ runArbDeck ⋙ \model →
  case Model.decode (Model.encode model) of
    Left err → Failed $ "Decode failed: " ⊕ err
    Right model' → fold (zipWith checkCardEquality model.cards model'.cards)
