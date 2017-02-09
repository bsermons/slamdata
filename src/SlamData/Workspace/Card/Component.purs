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

module SlamData.Workspace.Card.Component
  ( CardComponent
  , makeCardComponent
  , module SlamData.Workspace.Card.Component.Def
  , module SlamData.Workspace.Card.Common
  , module CQ
  , module CS
  , module EQ
  ) where

import SlamData.Prelude

import Data.Foldable (elem)

import DOM.HTML.HTMLElement (getBoundingClientRect)

import Halogen as H
import Halogen.Component.Utils (busEventSource)
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.HTML.Properties.ARIA as ARIA

import SlamData.Monad (Slam)
import SlamData.Workspace.Card.CardType (CardType(..), cardClasses, cardName, cardIconDarkSrc)
import SlamData.Workspace.Card.Common.EvalQuery as EQ
import SlamData.Workspace.Card.Common (CardOptions)
import SlamData.Workspace.Card.Component.CSS as CSS
import SlamData.Workspace.Card.Component.Def (CardDef, makeQueryPrism, makeQueryPrism')
import SlamData.Workspace.Card.Component.Query as CQ
import SlamData.Workspace.Card.Component.State as CS
import SlamData.Workspace.Eval.Card as Card
import SlamData.Workspace.Eval.Persistence as P

-- | Type synonym for the full type of a card component.
type CardComponent = H.Component HH.HTML CQ.CardQuery Unit Void Slam
type CardDSL f = H.ParentDSL CS.CardState CQ.CardQuery (CQ.InnerCardQuery f) Unit Void Slam
type CardHTML f = H.ParentHTML CQ.CardQuery (CQ.InnerCardQuery f) Unit Slam

cardRef ∷ H.RefLabel
cardRef = H.RefLabel "card"

-- | Card component factory
makeCardComponent
  ∷ ∀ s f
  . CardDef s f ()
  → CardComponent
makeCardComponent def = makeCardComponentPart def render
  where
  render
    ∷ H.Component HH.HTML (CQ.InnerCardQuery f) s EQ.CardEvalMessage Slam
    → s
    → CS.CardState
    → CardHTML f
  render component initialState st =
    HH.div
      [ HP.classes $ [ CSS.deckCard ]
      , ARIA.label $ (cardName def.cardType) ⊕ " card"
      , HP.ref cardRef
      ]
      $ fold [cardLabel, card]
    where
    cardLabel ∷ Array (CardHTML f)
    cardLabel
      | def.cardType `elem` [ Draftboard ] = []
      | otherwise =
          [ HH.div
              [ HP.classes [CSS.cardHeader]
              ]
              [ HH.div
                  [ HP.class_ CSS.cardName ]
                  [ HH.img [ HP.src $ cardIconDarkSrc def.cardType ]
                  , HH.p_ [ HH.text $ cardName def.cardType ]
                  ]
              ]
          ]
    card ∷ Array (CardHTML f)
    card =
      if st.pending
        then []
        else
          [ HH.div
              [ HP.classes (cardClasses def.cardType) ]
              [ HH.slot unit component initialState (HE.input CQ.HandleCardMessage) ]
          ]

-- | Constructs a card component from a record with the necessary properties and
-- | a render function.
makeCardComponentPart
  ∷ ∀ s f r
  . CardDef s f r
  → (H.Component HH.HTML (CQ.InnerCardQuery f) s EQ.CardEvalMessage Slam
     → s
     → CS.CardState
     → CardHTML f)
  → CardComponent
makeCardComponentPart def render =
  H.lifecycleParentComponent
    { render: render def.component def.initialState
    , eval
    , initialState: const (CS.initialCardState)
    , initializer: Just (H.action CQ.Initialize)
    , finalizer: Just (H.action CQ.Finalize)
    , receiver: const Nothing
    }
  where
  displayCoord ∷ Card.DisplayCoord
  displayCoord = def.options.cursor × def.options.cardId

  eval ∷ CQ.CardQuery ~> CardDSL f
  eval = case _ of
    CQ.Initialize next → do
      initializeInnerCard
      pure next
    CQ.Finalize next → do
      H.modify _ { sub = H.Done }
      pure next
    CQ.ActivateCard next →
      queryInnerCard EQ.Activate $> next
    CQ.DeactivateCard next →
      queryInnerCard EQ.Deactivate $> next
    CQ.UpdateDimensions next → do
      H.getHTMLElementRef cardRef >>= traverse_ \el → do
        { width, height } ← H.liftEff (getBoundingClientRect el)
        unless (width ≡ zero ∧ height ≡ zero) do
          queryInnerCard $ EQ.ReceiveDimensions { width, height }
      pure next
    CQ.HandleEvalMessage msg reply → do
      H.gets _.sub >>= \sub → do
        case sub of
          H.Done → pure unit
          H.Listening → case msg of
            Card.Pending source (evalPort × varMap) → do
              queryInnerCard $ EQ.ReceiveInput evalPort varMap
            Card.Complete source (evalPort × varMap) → do
              queryInnerCard $ EQ.ReceiveOutput evalPort varMap
            Card.StateChange source evalState →
              queryInnerCard $ EQ.ReceiveState evalState
            Card.ModelChange source evalModel →
              when (source ≠ displayCoord) do
                queryInnerCard $ EQ.Load evalModel
        pure (reply sub)
    CQ.HandleCardMessage msg next → do
      case msg of
        EQ.ModelUpdated EQ.EvalModelUpdate → do
          model ← H.query unit (left (H.request EQ.Save))
          for_ model (H.lift ∘ P.publishCardChange displayCoord)
        EQ.ModelUpdated (EQ.EvalStateUpdate es) → do
          H.lift $ P.publishCardStateChange displayCoord es
        EQ.ModelUpdated EQ.StateOnlyUpdate → pure unit
        EQ.ZoomIn → pure unit -- TODO???
      pure next

  initializeInnerCard ∷ CardDSL f Unit
  initializeInnerCard = do
    cell ← H.lift $ P.getCard def.options.cardId
    for_ cell \{ bus, model, input, output, state } → do
      H.subscribe $ busEventSource (H.request ∘ CQ.HandleEvalMessage) bus
      H.modify _
        { bus = Just bus
        , pending = false
        }
      queryInnerCard $ EQ.Load model
      for_ input (queryInnerCard ∘ uncurry EQ.ReceiveInput)
      for_ state (queryInnerCard ∘ EQ.ReceiveState)
      for_ output (queryInnerCard ∘ uncurry EQ.ReceiveOutput)
      eval (CQ.UpdateDimensions unit)

queryInnerCard ∷ ∀ f. H.Action EQ.CardEvalQuery → CardDSL f Unit
queryInnerCard q =
  void $ H.query unit (left (H.action q))
