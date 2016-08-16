{-
Copyright 2016 SlamData, Inc.

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

module SlamData.Quasar.Auth.Retrieve where

import SlamData.Prelude

import Control.Apply as Apply
import Control.Coroutine as Coroutine
import Control.Coroutine.Stalling (($$?))
import Control.Coroutine.Stalling as StallingCoroutine
import Control.Monad.Aff (Aff)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar, AVAR)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Bus (Bus, Cap)
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Control.Monad.Eff.Random (RANDOM)
import Control.Monad.Except.Trans (ExceptT(..), runExceptT)

import Data.Date as Date
import Data.Int as Int
import Data.Either as E
import Data.Maybe as M
import Data.Foldable as F
import Data.Traversable as T
import Control.UI.Browser as Browser

import DOM (DOM)

import OIDC.Crypt.Types as OIDCT
import OIDC.Crypt as OIDC

import SlamData.Quasar.Auth.Keys as AuthKeys
import SlamData.Quasar.Auth.Reauthentication (EIdToken)

import Quasar.Advanced.Types as QAT

import Utils.LocalStorage as LS
import Utils (passover)

fromEither ∷ ∀ a b. E.Either a b → M.Maybe b
fromEither = E.either (\_ → M.Nothing) (M.Just)

retrieveProvider ∷ ∀ e. Eff (dom ∷ DOM | e) (M.Maybe QAT.Provider)
retrieveProvider =
  LS.getLocalStorage AuthKeys.providerLocalStorageKey <#> fromEither

retrieveProviderR ∷ ∀ e. Eff (dom ∷ DOM | e) (M.Maybe QAT.ProviderR)
retrieveProviderR = map QAT.runProvider <$> retrieveProvider

retrieveKeyString ∷ ∀ e. Eff (dom ∷ DOM | e) (M.Maybe OIDCT.KeyString)
retrieveKeyString =
  LS.getLocalStorage AuthKeys.keyStringLocalStorageKey <#> fromEither <<< map OIDCT.KeyString

retrieveNonce ∷ ∀ e. Eff (dom ∷ DOM | e) (M.Maybe OIDCT.UnhashedNonce)
retrieveNonce =
  LS.getLocalStorage AuthKeys.nonceLocalStorageKey <#>
    E.either (\_ → M.Nothing) (M.Just <<< OIDCT.UnhashedNonce)

retrieveClientID ∷ ∀ e. Eff (dom ∷ DOM | e) (M.Maybe OIDCT.ClientID)
retrieveClientID =
  map _.clientID <$> retrieveProviderR

fromStallingProducer :: forall o eff. StallingCoroutine.StallingProducer o (Aff (avar :: AVAR | eff)) Unit → Aff (avar :: AVAR | eff) o
fromStallingProducer producer = do
  var ← AVar.makeVar
  StallingCoroutine.runStallingProcess
    (producer $$? (Coroutine.consumer \e → liftAff (AVar.putVar var e) $> Just unit))
  AVar.takeVar var

type RetrieveIdTokenEffRow eff = (console :: CONSOLE, rsaSignTime :: OIDC.RSASIGNTIME, avar :: AVAR, dom :: DOM, random :: RANDOM | eff)

retrieveIdToken ∷ ∀ r eff. (Bus (write ∷ Cap | r) (AVar EIdToken)) → Aff (RetrieveIdTokenEffRow eff) EIdToken
retrieveIdToken requestNewIdTokenBus =
  AVar.takeVar =<< passover (flip Bus.write requestNewIdTokenBus) =<< AVar.makeVar