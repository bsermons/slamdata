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

module SlamData.Workspace.Card.Setups.Chart.Candlestick.Component
  ( candlestickBuilderComponent
  ) where

import SlamData.Prelude

import Data.Lens ((.~), (^.), (^?))

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
--import Halogen.HTML.Events as HE

import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.CardType.ChartType as CHT
import SlamData.Workspace.Card.Component as CC
import SlamData.Workspace.Card.Eval.State as ES
import SlamData.Workspace.Card.Model as Card
import SlamData.Workspace.Card.Setups.ActionSelect.Component as AS
import SlamData.Workspace.Card.Setups.CSS as CSS
import SlamData.Workspace.Card.Setups.Chart.Candlestick.Component.ChildSlot as CS
import SlamData.Workspace.Card.Setups.Chart.Candlestick.Component.Query as Q
import SlamData.Workspace.Card.Setups.Chart.Candlestick.Component.State as ST
import SlamData.Workspace.Card.Setups.DimensionPicker.JCursor as DJ
import SlamData.Workspace.Card.Setups.DimensionPicker.Component as DPC
import SlamData.Workspace.Card.Setups.Inputs as I
import SlamData.Workspace.Card.Setups.Transform as T
import SlamData.Workspace.Card.Setups.Transform.Aggregation as Ag
import SlamData.Workspace.LevelOfDetails (LevelOfDetails(..))

type DSL = CC.InnerCardParentDSL ST.State Q.Query CS.ChildQuery CS.ChildSlot
type HTML = CC.InnerCardParentHTML Q.Query CS.ChildQuery CS.ChildSlot

candlestickBuilderComponent ∷ CC.CardOptions → CC.CardComponent
candlestickBuilderComponent =
  CC.makeCardComponent (CT.ChartOptions CHT.Candlestick) $ H.parentComponent
    { render
    , eval: cardEval ⨁ setupEval
    , receiver: const Nothing
    , initialState: const ST.initialState
    }

render ∷ ST.State → HTML
render state =
  HH.div
    [ HP.classes [ CSS.chartEditor ]
    ]
    $ ( renderButton state <$> ST.allFields )
    ⊕ [ renderSelection state ]

renderSelection ∷ ST.State → HTML
renderSelection state = case state ^. ST._selected of
  Nothing → HH.text ""
  Just (Right tp) →
    HH.slot' CS.cpTransform unit AS.component
      { options: ST.transforms state
      , selection: Just $ T.Aggregation Ag.Sum
      , title: "Choose transformation"
      , label: T.prettyPrintTransform
      , deselectable: false
      }
      (const Nothing)
--      (Just ∘ right ∘ H.action ∘ M.OnField tp ∘ M.HandleTransformPicker)
  Just (Left pf) →
    let
      conf =
        { title: ST.chooseLabel pf
        , label: DPC.labelNode DJ.showJCursorTip
        , render: DPC.renderNode DJ.showJCursorTip
        , values: DJ.groupJCursors $ ST.cursors state
        , isSelectable: DPC.isLeafPath
        }
    in
      HH.slot'
        CS.cpPicker
        unit
        (DPC.picker conf)
        unit
        (const Nothing)
--        (Just ∘ right ∘ H.action ∘ M.OnField pf ∘ M.HandleDPMessage)


renderButton ∷ ST.State → ST.Projection → HTML
renderButton state fld =
  HH.form [ HP.classes [ HH.ClassName "chart-configure-form" ] ]
  [ I.dimensionButton
    { configurable: false
    , dimension: sequence $ ST.getSelected fld state
    , showLabel: absurd
    , showDefaultLabel: ST.showDefaultLabel fld
    , showValue: ST.showValue fld
    , onLabelChange: const Nothing --HE.input \l → right ∘ M.OnField fld ∘ M.LabelChanged l
    , onDismiss: const Nothing --HE.input_ $ right ∘ M.OnFieldxo fld ∘ M.Dismiss
    , onConfigure: const Nothing --HE.input_ $ right ∘ M.OnField fld ∘ M.Configure
    , onClick: const Nothing --HE.input_ $ right ∘ M.OnField fld ∘ M.Select
    , onMouseDown: const Nothing
    , onLabelClick: const Nothing
    , disabled: ST.disabled fld state
    , dismissable: isJust $ ST.getSelected fld state
    } ]

cardEval ∷ CC.CardEvalQuery ~> DSL
cardEval = case _ of
  CC.Activate next →
    pure next
  CC.Deactivate next →
    pure next
  CC.Save k → do
    st ← H.get
    pure $ k $ Card.BuildCandlestick $ ST.save st
  CC.Load (Card.BuildCandlestick m) next → do
    H.modify $ ST.load m
    pure next
  CC.Load card next →
    pure next
  CC.ReceiveInput _ _ next →
    pure next
  CC.ReceiveOutput _ _ next →
    pure next
  CC.ReceiveState evalState next → do
    for_ (evalState ^? ES._Axes) \axes → do
      H.modify $ ST._axes .~ axes
    pure next
  CC.ReceiveDimensions dims reply → do
    pure $ reply
      if dims.width < 576.0 ∨ dims.height < 416.0
      then Low
      else High

setupEval ∷ Q.Query ~> DSL
setupEval = case _ of
  Q.Misc q →
    absurd $ unwrap q
  Q.OnField fld fldQuery → case fldQuery of
    Q.Select next → do
      H.modify $ ST.select fld
      pure next
    Q.Configure next → do
      H.modify $ ST.configure fld
      pure next
    Q.Dismiss next → do
      H.modify $ ST.clear fld
      pure next
    Q.LabelChanged str next → do
      H.modify $ ST.setLabel fld str
      pure next
    Q.HandleDPMessage m next → case m of
      DPC.Dismiss → do
        H.modify ST.deselect
        pure next
      DPC.Confirm value → do
        st ← H.get
        H.modify
          $ ( ST.setValue fld $ DJ.flattenJCursors value )
          ∘ ( ST.deselect )
        raiseUpdate
        pure next
    Q.HandleTransformPicker msg next → do
      case msg of
        AS.Dismiss →
          H.modify ST.deselect
        AS.Confirm mbt → do
          H.modify
            $ ST.deselect
            ∘ ST.setTransform fld mbt
          raiseUpdate
      pure next

raiseUpdate ∷ DSL Unit
raiseUpdate = do
  H.raise CC.modelUpdate
