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

module SlamData.Workspace.Component
  ( component
  , module SlamData.Workspace.Component.Query
  ) where

import SlamData.Prelude

import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (makeVar, peekVar, takeVar)
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Eff.Ref (readRef)
import Control.UI.Browser as Browser

import Data.List as List
import Data.Time.Duration (Milliseconds(..))

import DOM.Classy.Event (currentTarget, target) as DOM
import DOM.Classy.Node (toNode) as DOM

import Halogen as H

import Halogen.Component.Utils (busEventSource)
import Halogen.Component.Utils.Throttled (throttledEventSource_)
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Themes.Bootstrap3 as B

import SlamData.AuthenticationMode as AuthenticationMode
import SlamData.FileSystem.Resource as R
import SlamData.GlobalError as GE
import SlamData.GlobalMenu.Bus (SignInMessage(..))
import SlamData.Guide.StepByStep.Component as Guide
import SlamData.Header.Component as Header
import SlamData.Monad (Slam)
import SlamData.Notification.Component as NC
import SlamData.Quasar as Quasar
import SlamData.Quasar.Auth.Authentication as Authentication
import SlamData.Quasar.Error as QE
import SlamData.Wiring as Wiring
import SlamData.Wiring.Cache as Cache
import SlamData.Workspace.AccessType as AT
import SlamData.Workspace.Action as WA
import SlamData.Workspace.Card.Model as CM
import SlamData.Workspace.Card.Table.Model as JT
import SlamData.Workspace.Class (navigate, Routes(..))
import SlamData.Workspace.Component.ChildSlot (ChildQuery, ChildSlot, cpDeck, cpGuide, cpHeader, cpNotify)
import SlamData.Workspace.Component.Query (Query(..))
import SlamData.Workspace.Component.State (State, initialState)
import SlamData.Workspace.Deck.Component as Deck
import SlamData.Workspace.Eval.Deck as ED
import SlamData.Workspace.Eval.Persistence as P
import SlamData.Workspace.Eval.Traverse as ET
import SlamData.Workspace.Guide (GuideType(..))
import SlamData.Workspace.Guide as GuideData
import SlamData.Workspace.StateMode (StateMode(..))

import Utils (endSentence)
import Utils.DOM (onResize, nodeEq)
import Utils.LocalStorage as LocalStorage

type WorkspaceHTML = H.ParentHTML Query ChildQuery ChildSlot Slam
type WorkspaceDSL = H.ParentDSL State Query ChildQuery ChildSlot Void Slam

component ∷ AT.AccessType → H.Component HH.HTML Query Unit Void Slam
component accessType =
  H.lifecycleParentComponent
    { initialState: const initialState
    , render: render accessType
    , eval
    , initializer: Just $ Init unit
    , finalizer: Nothing
    , receiver: const Nothing
    }

render ∷ AT.AccessType → State → WorkspaceHTML
render accessType state =
  HH.div
    [ HP.classes
        $ (guard (AT.isReadOnly accessType) $> HH.ClassName "sd-published")
        ⊕ [ HH.ClassName "sd-workspace" ]
    , HE.onClick (HE.input DismissAll)
    ]
    (header ⊕ deck ⊕ notifications ⊕ renderCardGuide ⊕ renderFlipGuide)
  where
  renderError err =
    HH.div
      [ HP.classes [ HH.ClassName "sd-workspace-error" ] ]
      [ HH.h1_
          [ HH.text "Couldn't load this SlamData workspace." ]
      , HH.p_
          [ HH.text $ endSentence $ QE.printQError err ]
      , if (QE.isUnauthorized err)
          then HH.p_ (renderSignInButton <$> state.providers)
          else HH.text ""
      ]

  renderSignInButton providerR =
      HH.button
        [ HE.onClick $ HE.input_ $ SignIn providerR
        , HP.classes [ HH.ClassName "btn", HH.ClassName "btn-primary" ]
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text $ "Sign in with " ⊕ providerR.displayName ]

  renderCardGuide =
    pure $
      HH.div
        [ HP.classes (guard (state.guide /= Just CardGuide) $> B.hidden) ]
        [ HH.slot' cpGuide CardGuide Guide.component GuideData.cardGuideSteps (HE.input (HandleGuideMessage CardGuide)) ]

  renderFlipGuide =
    pure $
      HH.div
        [ HP.classes (guard (state.guide /= Just FlipGuide) $> B.hidden) ]
        [ HH.slot' cpGuide FlipGuide Guide.component GuideData.flipGuideSteps (HE.input (HandleGuideMessage FlipGuide)) ]

  notifications =
    pure $ HH.slot' cpNotify unit (NC.comp (NC.renderModeFromAccessType accessType)) unit absurd

  header = do
    guard $ AT.isEditable accessType
    pure $ HH.slot' cpHeader unit Header.component unit absurd

  deck =
    pure case state.stateMode, state.cursor of
      Error error, _ → renderError error
      Loading, _ →
        HH.div
          [ HP.class_ $ HH.ClassName "sd-pending-overlay" ]
          [ HH.div_
              [ HH.i_ []
              , HH.span_ [ HH.text "Please wait while the workspace loads" ]
              ]
          ]
      _, List.Cons deckId cursor →
        HH.slot' cpDeck deckId (Deck.component { accessType, cursor, displayCursor: mempty, deckId }) unit (const Nothing)
      _, _ → HH.text "Error"

eval ∷ Query ~> WorkspaceDSL
eval = case _ of
  Init next → do
    { bus, accessType } ← H.lift Wiring.expose
    cardGuideStep ← initialCardGuideStep
    -- TODO:
    -- when (AT.isEditable accessType) do
    --   H.modify _ { cardGuideStep = cardGuideStep }
    H.subscribe $ busEventSource
      (H.request ∘ PresentStepByStepGuide)
      bus.stepByStep
    H.subscribe
      $ throttledEventSource_ (Milliseconds 100.0) onResize (H.request Resize)
    -- The deck component isn't initialised before this later has completed
    H.liftAff $ Aff.later (pure unit)
    when (isNothing cardGuideStep) do
      void $ queryDeck $ H.action Deck.DismissedCardGuide
    pure next
  PresentStepByStepGuide guideType reply → do
    H.modify (_ { guide = Just guideType })
    pure $ reply H.Listening
  DismissAll ev next → do
    void $ H.query' cpHeader unit $ H.action Header.Dismiss
    eq ← H.liftEff $ nodeEq (DOM.toNode (DOM.target ev)) (DOM.toNode (DOM.currentTarget ev))
    when eq $ void $ queryDeck $ H.action Deck.Focus
    pure next
  Resize reply → do
    queryDeck (H.action Deck.UpdateCardSize)
    pure $ reply H.Listening
  New next → do
    st ← H.get
    when (List.null st.cursor) do
      runFreshWorkspace mempty
    pure next
  ExploreFile res next → do
    st ← H.get
    when (List.null st.cursor) do
      runFreshWorkspace
        [ CM.Open (R.File res)
        , CM.Table JT.emptyModel
        ]
    pure next
  Load cursor next → do
    st ← H.get
    case st.stateMode of
      Loading → do
        rootId ← H.lift P.loadWorkspace
        case rootId of
          Left err → do
            providers ←
              Quasar.retrieveAuthProviders <#> case _ of
                Right (Just providers) → providers
                _ → []
            H.modify _
              { stateMode = Error err
              , providers = providers
              }
            for_ (GE.fromQError err) GE.raiseGlobalError
          Right _ → loadCursor cursor
      _ → loadCursor cursor
    void $ queryDeck $ H.action Deck.Focus
    pure next
  SignIn providerR next → do
    { auth } ← H.lift Wiring.expose
    idToken ← H.liftAff makeVar
    H.liftAff $ Bus.write { providerR, idToken, prompt: true, keySuffix } auth.requestToken
    either signInFailure (const $ signInSuccess) =<< (H.liftAff $ takeVar idToken)
    pure next
  HandleGuideMessage slot Guide.Dismissed next → do
    case slot of
      CardGuide → do
        H.lift $ LocalStorage.setLocalStorage GuideData.dismissedCardGuideKey true
        void $ queryDeck $ H.action Deck.DismissedCardGuide
      FlipGuide → do
        H.lift $ LocalStorage.setLocalStorage GuideData.dismissedFlipGuideKey true
    H.modify (_ { guide = Nothing })
    pure next

  where
  loadCursor cursor = do
    cursor' ←
      if List.null cursor
        then do
          wiring ← H.lift Wiring.expose
          rootId ← H.liftAff $ peekVar wiring.eval.root
          pure (pure rootId)
        else
          hydrateCursor cursor
    H.modify _
      { stateMode = Ready
      , cursor = cursor'
      }

  hydrateCursor cursor = H.lift do
    wiring ← Wiring.expose
    ET.hydrateCursor
      <$> Cache.snapshot wiring.eval.decks
      <*> Cache.snapshot wiring.eval.cards
      <*> pure cursor

  keySuffix =
    AuthenticationMode.toKeySuffix AuthenticationMode.ChosenProvider

  signInSuccess = do
    { auth } ← H.lift Wiring.expose
    H.liftAff $ Bus.write SignInSuccess $ auth.signIn
    H.liftEff Browser.reload

  signInFailure error = do
    { auth, bus } ← H.lift Wiring.expose
    H.liftAff do
      for_ (Authentication.toNotificationOptions error) $
        flip Bus.write bus.notify
      Bus.write SignInFailure auth.signIn

runFreshWorkspace ∷ Array CM.AnyCardModel → WorkspaceDSL Unit
runFreshWorkspace cards = do
  { path, accessType, varMaps, bus } ← H.lift Wiring.expose
  deckId × cell ← H.lift $ P.freshWorkspace cards
  H.modify _
    { stateMode = Ready
    , cursor = pure deckId
    }
  void $ queryDeck $ H.action Deck.Focus
  let
    wait =
      H.liftAff (Bus.read cell.bus) >>= case _ of
        ED.Pending _ → wait
        ED.Complete _ _ → wait
        ED.CardComplete _ → wait
        ED.CardChange _ → H.gets _.cursor
        ED.NameChange _ → H.gets _.cursor
  cursor ← wait
  H.lift P.saveWorkspace
  urlVarMaps ← H.liftEff $ readRef varMaps
  navigate $ WorkspaceRoute path cursor (WA.Load accessType) urlVarMaps

-- TODO:
-- peek ∷ ∀ a. ChildQuery a → WorkspaceDSL Unit
-- peek = (const (pure unit)) ⨁ const (pure unit) ⨁ peekNotification
--   where
--   peekNotification ∷ NC.Query a → WorkspaceDSL Unit
--   peekNotification = case _ of
--     NC.Action N.ExpandGlobalMenu _ → do
--       queryHeaderGripper $ Gripper.StartDragging 0.0 unit
--       queryHeaderGripper $ Gripper.StopDragging unit
--     NC.Action (N.Fulfill var) _ →
--       void $ H.liftAff $ Aff.attempt $ putVar var unit
--     _ → pure unit

queryDeck ∷ ∀ a. Deck.Query a → WorkspaceDSL (Maybe a)
queryDeck q = do
  deckId ← H.gets (List.head ∘ _.cursor)
  join <$> for deckId \d → H.query' cpDeck d q

initialCardGuideStep ∷ WorkspaceDSL (Maybe Int)
initialCardGuideStep =
  H.lift
    $ either (const $ Just 0) (if _ then Nothing else Just 0)
    <$> LocalStorage.getLocalStorage GuideData.dismissedCardGuideKey
