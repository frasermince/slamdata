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

module SlamData.Workspace.Card.Ace.Component
  ( aceComponent
  , DSL
  , HTML
  , module SlamData.Workspace.Card.Ace.Component.Query
  , module SlamData.Workspace.Card.Ace.Component.State
  ) where

import SlamData.Prelude

import Ace.Editor as Editor
import Ace.EditSession as Session
import Ace.Halogen.Component as AC
import Ace.Types (Editor)

import Control.Monad.Aff.AVar (makeVar, takeVar)

import Data.Array as Array
import Data.String as Str
import Data.StrMap as SM

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.HTML.Properties.ARIA as ARIA
import Halogen.Themes.Bootstrap3 as B
import Halogen.Component.Utils (affEventSource)

import SlamData.Monad (Slam)
import SlamData.Notification as N
import SlamData.Render.Common (glyph)
import SlamData.Render.CSS as CSS
import SlamData.Workspace.Card.Ace.Component.Query (Query(..))
import SlamData.Workspace.Card.Ace.Component.State (State, initialState)
import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.Component as CC
import SlamData.Workspace.Card.Model as Card
import SlamData.Workspace.Card.Port as Port
import SlamData.Workspace.LevelOfDetails (LevelOfDetails(..))

import Utils.Ace (getRangeRecs, readOnly)

type DSL = H.ParentDSL State (CC.InnerCardQuery Query) AC.AceQuery Unit CC.CardEvalMessage Slam
type HTML = H.ParentHTML (CC.InnerCardQuery Query) AC.AceQuery Unit Slam

aceComponent ∷ CT.AceMode → CC.CardOptions → CC.CardComponent
aceComponent mode =
  CC.makeCardComponent (CT.Ace mode) $ H.lifecycleParentComponent
    { render: render mode
    , eval: evalCard mode ⨁ evalComponent
    , initialState: const initialState
    , initializer: Just $ right $ H.action Init
    , finalizer: Nothing
    , receiver: const Nothing
    }

evalComponent ∷ Query ~> DSL
evalComponent = case _ of
  Init next → do
    trigger ← H.liftAff $ makeVar
    H.modify _ { trigger = Just trigger }
    H.subscribe $ affEventSource
      (const $ right $ RunQuery H.Listening)
      (takeVar trigger)
    pure next
  RunQuery next → do
    H.raise CC.modelUpdate
    H.modify _ { dirty = false }
    pure next
  HandleAce (AC.TextChanged str) next → do
    unlessM (H.gets _.dirty) do
      H.modify _ { dirty = true }
    pure next

evalCard ∷ CT.AceMode → CC.CardEvalQuery ~> DSL
evalCard mode = case _ of
  CC.Activate next → do
    mbEditor ← H.query unit $ H.request AC.GetEditor
    for_ (join mbEditor) $ H.liftEff ∘ Editor.focus
    pure next
  CC.Deactivate next → do
    st ← H.get
    for_ st.trigger \trigger →
      when st.dirty do
        N.info "Don't forget to run your query to see the latest result."
          Nothing
          Nothing
          (Just $ N.ActionOptions
            { message: ""
            , actionMessage: "Run query now"
            , action: N.Fulfill trigger
            })
    pure next
  CC.Save k → do
    content ← fromMaybe "" <$> H.query unit (H.request AC.GetText)
    mbEditor ← H.query unit (H.request AC.GetEditor)
    rrs ← H.liftEff $ maybe (pure []) getRangeRecs $ join mbEditor
    pure ∘ k
      $ Card.Ace mode { text: content, ranges: rrs }
  CC.Load card next → do
    case card of
      Card.Ace _ { text, ranges } → do
        H.query unit $ H.action $ AC.SetText text
        mbEditor ← H.query unit $ H.request AC.GetEditor
        H.liftEff $ for_ (join mbEditor) \editor → do
          traverse_ (readOnly editor) ranges
          Editor.navigateFileEnd editor
      _ → pure unit
    H.modify _ { dirty = false }
    pure next
  CC.ReceiveInput _ varMaps next → do
    let vars = SM.keys varMaps
    H.query unit $ H.action $ AC.SetCompleteFn \_ _ _ inp → do
      let inp' = Str.toLower inp
      pure $ flip Array.mapMaybe vars \var → do
        guard $ Str.contains (Str.Pattern inp') (Str.toLower var)
        pure
          { value: ":" <> Port.escapeIdentifier var
          , score: 200.0
          , caption: Just var
          , meta: "var"
          }
    pure next
  CC.ReceiveOutput _ _ next →
    pure next
  CC.ReceiveState _ next → do
    pure next
  CC.ReceiveDimensions dims reply → do
    mbEditor ← H.query unit $ H.request AC.GetEditor
    for_ (join mbEditor) $ H.liftEff ∘ Editor.resize Nothing
    pure $ reply if dims.width < 240.0 then Low else High

aceSetup ∷ CT.AceMode → Editor → Slam Unit
aceSetup mode editor = H.liftEff do
  Editor.setTheme "ace/theme/chrome" editor
  Editor.setEnableLiveAutocompletion true editor
  Editor.setEnableBasicAutocompletion true editor
  Session.setMode (CT.aceMode mode) =<< Editor.getSession editor

render ∷ CT.AceMode → State → HTML
render mode state =
  HH.div
    [ HP.classes [ CSS.cardInput, CSS.aceContainer ] ]
    [ HH.div [ HP.class_ (HH.ClassName "sd-ace-inset-shadow") ] []
    , HH.div
        [ HP.class_ (HH.ClassName "sd-ace-toolbar") ]
        [ HH.button
            [ HP.class_ (HH.ClassName "sd-ace-run")
            , HP.disabled (not state.dirty)
            , HP.title "Run Query"
            , ARIA.label "Run query"
            , HE.onClick (HE.input_ (right ∘ RunQuery))
            ]
            [ glyph B.glyphiconPlay
            , HH.text "Run Query"
            ]
        ]
    , HH.slot unit (AC.aceComponent (aceSetup mode) (Just AC.Live)) unit
        (Just ∘ right ∘ H.action ∘ HandleAce)
    ]
