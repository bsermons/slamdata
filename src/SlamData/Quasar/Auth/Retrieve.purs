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
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Random (RANDOM)
import Control.Monad.Except.Trans (ExceptT(..), runExceptT)

import Data.Date as Date
import Data.Date (Now)
import Data.Int as Int
import Data.Either as E
import Data.Maybe as M
import Data.Foldable as F
import Data.Time (Milliseconds(..))
import Data.Traversable as T
import Control.UI.Browser as Browser

import DOM (DOM)
import DOM.HTML as DOMHTML

import OIDCCryptUtils.Types as OIDCT
import OIDCCryptUtils.JSONWebKey (JSONWebKey)
import OIDCCryptUtils as OIDC

import SlamData.Config as Config
import SlamData.Quasar.Auth.Keys as AuthKeys
import SlamData.Quasar.Auth.IdTokenStorageEvents as IdTokenStorageEvents
import OIDC.Aff as OIDCAff

import Quasar.Advanced.Types as QAT

import Utils.LocalStorage as LS
import Utils.DOM as DOMUtils
import Utils.At as At
import Utils.At (INTERVAL)

foreign import log :: forall eff. String → Eff (dom :: DOM | eff) Unit

race ∷ Aff _ _ → Aff _ _ → Aff _ _
race a1 a2 = do
  va <- AVar.makeVar -- the `a` value
  ve <- AVar.makeVar -- the error count (starts at 0)
  AVar.putVar ve 0
  c1 <- Aff.forkAff $ either (maybeKill va ve) (AVar.putVar va) =<< Aff.attempt a1
  c2 <- Aff.forkAff $ either (maybeKill va ve) (AVar.putVar va) =<< Aff.attempt a2
  AVar.takeVar va `Aff.cancelWith` (c1 <> c2)
  where
  maybeKill va ve err = do
    e <- AVar.takeVar ve
    if e == 1 then AVar.killVar va err else pure unit
    AVar.putVar ve (e + 1)

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

type RetrieveIdTokenEffRow eff = (now ∷ Now, interval ∷ INTERVAL, rsaSignTime :: OIDC.RSASIGNTIME, avar :: AVAR, dom :: DOM, random :: RANDOM | eff)

retrieveIdToken ∷ ∀ eff. Aff (RetrieveIdTokenEffRow eff) (M.Maybe OIDCT.IdToken)
retrieveIdToken =
  fromEither
    <$> spy
    <$> (runExceptT
           $ (\idToken → (ExceptT $ verify idToken) <|> (ExceptT getNewToken))
           =<< ExceptT retrieveFromLocalStorage)
  where
  retrieveFromLocalStorage
    ∷ Aff (RetrieveIdTokenEffRow eff) (E.Either String OIDCT.IdToken)
  retrieveFromLocalStorage = do
    map OIDCT.IdToken <$> LS.getLocalStorage AuthKeys.idTokenLocalStorageKey

  retrieveGettingIdTokenUntil
    ∷ Aff (RetrieveIdTokenEffRow eff) (E.Either String Milliseconds)
  retrieveGettingIdTokenUntil = do
    map Milliseconds <$> LS.getLocalStorage AuthKeys.gettingIdTokenUntilKey

  storeGettingIdTokenUntil ∷ ∀ e. Milliseconds → Aff (dom ∷ DOM |e) Unit
  storeGettingIdTokenUntil ms = do
    LS.setLocalStorage AuthKeys.gettingIdTokenUntilKey (runMilliseconds ms)

  getNewToken ∷ Aff (RetrieveIdTokenEffRow eff) (E.Either String OIDCT.IdToken)
  getNewToken = do
    now ← liftEff Date.nowEpochMilliseconds
    gettingNewIdTokenUntilE ← retrieveGettingIdTokenUntil
    idTokenEventProducer ← liftEff $ IdTokenStorageEvents.getIdTokenStorageEvents
    case gettingNewIdTokenUntilE of
      Left _ → f now idTokenEventProducer
      Right gettingNewIdTokenUntil → do
        if now < gettingNewIdTokenUntil
          then (liftEff $ log "g") *> g gettingNewIdTokenUntil idTokenEventProducer
          else (liftEff $ log "f") *> f now idTokenEventProducer

  f now idTokenEventProducer = do
    x <- storeGettingIdTokenUntil now
      *> requestReauthentication
      *> retrieveFromLocalStorageAfterEvent idTokenEventProducer (addSeconds 30 now)
    storeGettingIdTokenUntil (Milliseconds 0.0)
    pure x

  g gettingNewIdTokenUntil idTokenEventProducer =
    retrieveFromLocalStorageAfterEvent idTokenEventProducer gettingNewIdTokenUntil

  requestReauthentication = do
    providerR ← liftEff retrieveProviderR
    maybe (pure unit) (either (const $ pure unit) (liftEff ∘ DOMUtils.openPopup) <=< liftEff ∘ requestAuthenticationURI) providerR

  retrieveFromLocalStorageAfterEvent idTokenEventProducer timeoutAt =
    race
      (fromStallingProducer idTokenEventProducer *> (liftEff $ log "eventhandle") *> retrieveFromLocalStorage)
      (At.at timeoutAt $ pure $ Left "No token recieved before timeout.")

  runMilliseconds ∷ Milliseconds → Number
  runMilliseconds (Milliseconds ms) = ms

  addSeconds ∷ Int → Milliseconds → Milliseconds
  addSeconds seconds = Milliseconds ∘ (_ + (Int.toNumber seconds * 1000.0)) ∘ runMilliseconds

  appendAuthPath s = s ++ Config.redirectURIString

  requestAuthenticationURI ∷ _ → _ (Either _ String)
  requestAuthenticationURI pr =
    OIDCAff.requestAuthenticationURI OIDCAff.None pr
      ∘ appendAuthPath
      =<< Browser.locationString

  verify
    ∷ OIDCT.IdToken
    → Aff (RetrieveIdTokenEffRow eff) (Either String OIDCT.IdToken)
  verify idToken = do
    verified ← liftEff $ verifyBoolean idToken
    if verified
      then do
        liftEff $ log "verified"
        pure $ Right idToken
      else do
        liftEff $ log "unverified"
        pure $ Left "Token invalid"

  verifyBoolean
    ∷ OIDCT.IdToken
    → Eff (RetrieveIdTokenEffRow eff) Boolean
  verifyBoolean idToken = do
    jwks ← map (M.fromMaybe []) retrieveJwks
    F.or <$> T.traverse (verifyBooleanWithJwk idToken) jwks

  verifyBooleanWithJwk
    ∷ OIDCT.IdToken
    → JSONWebKey
    → Eff (RetrieveIdTokenEffRow eff) Boolean
  verifyBooleanWithJwk idToken jwk = do
    issuer ← retrieveIssuer
    clientId ← retrieveClientID
    nonce ← retrieveNonce
    M.fromMaybe (pure false)
      $ Apply.lift4 (OIDC.verifyIdToken idToken) issuer clientId nonce (M.Just jwk)

  retrieveIssuer =
    map (_.issuer <<< _.openIDConfiguration) <$> retrieveProviderR

  retrieveJwks =
    map (_.jwks <<< _.openIDConfiguration) <$> retrieveProviderR

  ifFalseLeft ∷ ∀ a b. a → b → Boolean → Either a b
  ifFalseLeft x y boolean = if boolean then Right y else Left x
