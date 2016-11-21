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

module SlamData.ActionList.Component where

import SlamData.Prelude

import Data.Array as A
import Data.Foldable as F
import Data.Lens (Lens', lens, (.~))
import Data.String as S

import Halogen as H
import Halogen.HTML.Events.Indexed as HE
import Halogen.HTML.Indexed as HH
import Halogen.HTML.Properties.Indexed as HP
import Halogen.HTML.Properties.Indexed.ARIA as ARIA
import Halogen.Themes.Bootstrap3 as B

import SlamData.Monad (Slam)
import SlamData.Render.Common (glyph)

data Query a b
  = Selected (Action a) b
  | UpdateFilter String b
  | UpdateActions (Array (Action a)) b

type State a =
  { actions ∷ Array (Action a)
  , previousActions ∷ Array (Action a)
  , filterString ∷ String
  }

type HTML a = H.ComponentHTML (Query a)
type DSL a = H.ComponentDSL (State a) (Query a) Slam

newtype ActionIconUri = ActionIconUri String
newtype ActionName = ActionName String
newtype ActionDescription = ActionDescription String

data Action a
  = Do ActionName ActionIconUri ActionDescription a
  | Drill ActionName ActionIconUri ActionDescription (Array (Action a))
  | GoBack

_actions ∷ ∀ a r. Lens' { actions ∷ a |r } a
_actions = lens _.actions (_ { actions = _ })

_previousActions ∷ ∀ a r. Lens' { previousActions ∷ a | r} a
_previousActions = lens _.previousActions (_ { previousActions = _ })

_filterString ∷ ∀ a r. Lens' { filterString ∷ a | r } a
_filterString = lens _.filterString (_ { filterString = _ })

isDo ∷ ∀ a. Action a → Boolean
isDo (Do _ _ _ _) = true
isDo _ = false

isDrill ∷ ∀ a. Action a → Boolean
isDrill (Drill _ _ _ _) = true
isDrill _ = false

searchFilters ∷ ∀ a. Action a → Array String
searchFilters (Do (ActionName name) _ _ _) = [ name ]
searchFilters (Drill (ActionName name) _ _ actions) = [ name ] ⊕ A.concat (map searchFilters actions)
searchFilters (GoBack) = [ "go back" ]

derive newtype instance eqActionIconUri :: Eq ActionIconUri
derive newtype instance eqActionName :: Eq ActionName
derive newtype instance eqActionDescription :: Eq ActionDescription

instance eqAction ∷ Eq a ⇒ Eq (Action a) where
  eq GoBack GoBack = true
  eq (Do n1 i1 d1 a1) (Do n2 i2 d2 a2) =
    n1 ≡ n2
      ∧ i1 ≡ i2
      ∧ d1 ≡ d2
      ∧ a1 ≡ a2
  eq (Drill n1 i1 d1 a1) (Drill n2 i2 d2 a2) =
    n1 ≡ n2
      ∧ i1 ≡ i2
      ∧ d1 ≡ d2
      ∧ a1 ≡ a2
  eq _ _ = false

initialState ∷ ∀ a. State a
initialState =
  { actions: []
  , previousActions: [ ]
  , filterString: ""
  }

component ∷ ∀ a. Eq a ⇒ H.Component (State a) (Query a) Slam
component =
  H.component
    { render
    , eval
    }

render ∷ ∀ a. State a → HTML a
render state =
  HH.div_
    ([ HH.form_
        [ HH.div_
            [ HH.input
                [ HP.value state.filterString
                , HE.onValueInput (HE.input \s → UpdateFilter s)
                , ARIA.label "Filter next actions"
                , HP.placeholder "Filter actions"
                ]
            , HH.button
                [ HP.buttonType HP.ButtonButton
                , HE.onClick (HE.input_ $ UpdateFilter "")
                ]
                [ glyph B.glyphiconRemove ]
            ]
        ]
    ] ⊕ [ HH.ul_ $ map nextButton state.actions ])
  where

  filterString ∷ String
  filterString = S.toLower state.filterString

  nextButton ∷ Action a → HTML a
  nextButton action =
    HH.li_
      [ HH.button attrs
          [ HH.img [ HP.src $ actionIconUri action ]
          , HH.p_ [ HH.text $ actionName action ]
          ]
      ]
    where
    enabled ∷ Boolean
    enabled = case action of
      GoBack → true
      _ → F.any (S.contains (S.Pattern filterString) ∘ S.toLower) $ searchFilters action

    attrs =
      [ HP.title $ actionDescription action
      , HP.disabled $ not enabled
      , ARIA.label $ actionDescription action
      , HP.classes classes
      , HE.onClick (HE.input_ $ Selected action)
      ]

    actionDescription ∷ Action a → String
    actionDescription = case _ of
      Do _ _ (ActionDescription s) _ → s
      Drill _ _ (ActionDescription s) _ → s
      GoBack → "Go back"

    actionIconUri ∷ Action a → String
    actionIconUri = case _ of
      Do _ (ActionIconUri s) _ _ → s
      Drill _ (ActionIconUri s) _ _ → s
      GoBack → ""

    actionName ∷ Action a → String
    actionName = case _ of
      Do (ActionName s) _ _ _ → s
      Drill (ActionName s) _ _ _ → s
      GoBack → "Go back"

    classes ∷ Array HH.ClassName
    classes = case action of
      Do _ _ _ _ →
        nonInsertableClassNames
      Drill _ _ _ actions | not (F.any isDo actions) →
        nonInsertableClassNames
      _ →
        insertableClassNames

    insertableClassNames =
      [ HH.className "sd-button" ]

    nonInsertableClassNames =
        [ HH.className "sd-button", HH.className "sd-button-warning" ]

updateActions ∷ ∀ a. Eq a ⇒ Array (Action a) → State a → State a
updateActions newActions state =
  case activeDrill of
    Nothing →
      state
        { actions = newActions }
    Just drill →
      state
        { previousActions = newActions
        , actions = fromMaybe [] $ pluckDrillActions =<< newActiveDrill
        }
  where
  activeDrill ∷ Maybe (Action a)
  activeDrill =
    F.find
      (maybe false (eq state.actions) ∘ pluckDrillActions)
      state.previousActions

  newActiveDrill =
    F.find (eq activeDrill ∘ Just) newActions

  pluckDrillActions = case _ of
    Drill _ _ _ xs → Just xs
    _ → Nothing

eval ∷ ∀ a. Eq a ⇒ Query a ~> DSL a
eval = case _ of
  UpdateFilter str next →
    H.modify (_filterString .~ str) $> next
  Selected action next → do
    st ← H.get
    case action of
      Do _ _ _ _ → pure unit
      Drill _ _ _ actions →
        H.modify
          $ (_actions .~ actions)
          ∘ (_previousActions .~ st.actions)
      GoBack →
        H.modify
          $ (_actions .~ st.previousActions)
          ∘ (_previousActions .~ [ ])
    pure next
  UpdateActions actions next →
    H.modify (updateActions actions) $> next
