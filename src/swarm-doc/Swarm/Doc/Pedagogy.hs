{-# LANGUAGE OverloadedStrings #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
-- Description: Pedagogical soundness of tutorials
--
-- Assess pedagogical soundness of the tutorials.
--
-- Approach:
--
-- 1. Obtain a list of all of the tutorial scenarios, in order
-- 2. Search their \"solution\" code for `commands`
-- 3. "fold" over the tutorial list, noting which tutorial was first to introduce each command
module Swarm.Doc.Pedagogy (
  renderTutorialProgression,
  generateIntroductionsSequence,
  CoverageInfo (..),
  TutorialInfo (..),
) where

import Control.Lens (universe, view, (^.))
import Control.Monad (guard)
import Data.Foldable (Foldable (..))
import Data.List (intercalate, sort, sortOn)
import Data.List.Extra (zipFrom)
import Data.Map (Map)
import Data.Map qualified as M
import Data.Maybe (mapMaybe)
import Data.Sequence (Seq)
import Data.Set (Set)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Swarm.Constant
import Swarm.Failure (SystemFailure, simpleErrorHandle)
import Swarm.Game.Land
import Swarm.Game.Scenario (
  Scenario,
  ScenarioInputs (..),
  scenarioDescription,
  scenarioMetadata,
  scenarioName,
  scenarioObjectives,
  scenarioOperation,
  scenarioSolution,
 )
import Swarm.Game.Scenario.Objective (objectiveGoal)
import Swarm.Game.Scenario.Status
import Swarm.Game.ScenarioInfo (
  ScenarioCollection,
  flatten,
  getTutorials,
  loadScenarios,
  pathifyCollection,
  scenarioCollectionToList,
 )
import Swarm.Game.World.Load (loadWorlds)
import Swarm.Language.Syntax
import Swarm.Language.Text.Markdown (docToText, findCode)
import Swarm.Language.Types (Polytype)
import Swarm.Util.Effect (ignoreWarnings)
import Prelude hiding (Foldable (..))

-- * Constants

commandsWikiAnchorPrefix :: Text
commandsWikiAnchorPrefix = wikiCheatSheet <> "#"

-- * Types

-- | Tutorials augmented by the set of
-- commands that they introduce.
-- Generated by folding over all of the
-- tutorials in sequence.
data CoverageInfo = CoverageInfo
  { tutInfo :: TutorialInfo
  , novelSolutionCommands :: Map Const [SrcLoc]
  }

-- | Tutorial scenarios with the set of commands
-- introduced in their solution and descriptions
-- having been extracted
data TutorialInfo = TutorialInfo
  { scenarioPair :: ScenarioWith ScenarioPath
  , tutIndex :: Int
  , solutionCommands :: Map Const [SrcLoc]
  , descriptionCommands :: Set Const
  }

-- | A private type used by the fold
data CommandAccum = CommandAccum
  { _encounteredCmds :: Set Const
  , tuts :: [CoverageInfo]
  }

-- * Functions

-- | Extract commands from both goal descriptions and solution code.
extractCommandUsages :: Int -> ScenarioWith ScenarioPath -> TutorialInfo
extractCommandUsages idx siPair@(ScenarioWith s _si) =
  TutorialInfo siPair idx solnCommands $ getDescCommands s
 where
  solnCommands = getCommands maybeSoln
  maybeSoln = view (scenarioOperation . scenarioSolution) s

-- | Obtain the set of all commands mentioned by
-- name in the tutorial's goal descriptions.
getDescCommands :: Scenario -> Set Const
getDescCommands s = S.fromList $ concatMap filterConst allCode
 where
  goalTextParagraphs = view objectiveGoal <$> view (scenarioOperation . scenarioObjectives) s
  allCode = concatMap findCode goalTextParagraphs
  filterConst :: Syntax -> [Const]
  filterConst sx = mapMaybe toConst $ universe (sx ^. sTerm)
  toConst :: Term -> Maybe Const
  toConst = \case
    TConst c -> Just c
    _ -> Nothing

isConsidered :: Const -> Bool
isConsidered c = isUserFunc c && c `S.notMember` ignoredCommands
 where
  ignoredCommands = S.fromList [Run, Pure, Noop, Force]

-- | Extract the command names from the source code of the solution.
--
-- NOTE: `noop` gets automatically inserted for an empty `build {}` command
-- at parse time, so we explicitly ignore the `noop` in the case that
-- the player did not write it explicitly in their code.
--
-- Also, the code from `run` is not parsed transitively yet.
getCommands :: Maybe TSyntax -> Map Const [SrcLoc]
getCommands Nothing = mempty
getCommands (Just tsyn) =
  M.fromListWith (<>) $ mapMaybe isCommand nodelist
 where
  nodelist :: [Syntax' Polytype]
  nodelist = universe tsyn
  isCommand (Syntax' sloc t _ _) = case t of
    TConst c -> guard (isConsidered c) >> Just (c, [sloc])
    _ -> Nothing

-- | "fold" over the tutorials in sequence to determine which
-- commands are novel to each tutorial's solution.
computeCommandIntroductions :: [(Int, ScenarioWith ScenarioPath)] -> [CoverageInfo]
computeCommandIntroductions =
  reverse . tuts . foldl' f initial
 where
  initial = CommandAccum mempty mempty

  f :: CommandAccum -> (Int, ScenarioWith ScenarioPath) -> CommandAccum
  f (CommandAccum encounteredPreviously xs) (idx, siPair) =
    CommandAccum updatedEncountered $ CoverageInfo usages novelCommands : xs
   where
    usages = extractCommandUsages idx siPair
    usedCmdsForTutorial = solutionCommands usages

    updatedEncountered = encounteredPreviously `S.union` M.keysSet usedCmdsForTutorial
    novelCommands = M.withoutKeys usedCmdsForTutorial encounteredPreviously

-- | Extract the tutorials from the complete scenario collection
-- and derive their command coverage info.
generateIntroductionsSequence :: ScenarioCollection ScenarioInfo -> [CoverageInfo]
generateIntroductionsSequence =
  computeCommandIntroductions . zipFrom 0 . getTuts . pathifyCollection
 where
  getTuts =
    concatMap flatten
      . scenarioCollectionToList
      . getTutorials

-- * Rendering functions

-- | Helper for standalone rendering.
-- For unit tests, can instead access the scenarios via the GameState.
loadScenarioCollection :: IO (ScenarioCollection ScenarioInfo)
loadScenarioCollection = simpleErrorHandle $ do
  tem <- loadEntitiesAndTerrain

  -- Note we ignore any warnings generated by 'loadWorlds' and
  -- 'loadScenarios' below.  Any warnings will be caught when loading
  -- all the scenarios via the usual code path; we do not need to do
  -- anything with them here while simply rendering pedagogy info.
  worlds <- ignoreWarnings @(Seq SystemFailure) $ loadWorlds tem
  ignoreWarnings @(Seq SystemFailure) $ loadScenarios (ScenarioInputs worlds tem) True

renderUsagesMarkdown :: CoverageInfo -> Text
renderUsagesMarkdown (CoverageInfo (TutorialInfo (ScenarioWith s (ScenarioPath sp)) idx _sCmds dCmds) novelCmds) =
  T.unlines bodySections
 where
  bodySections = firstLine : otherLines
  otherLines =
    intercalate
      [""]
      [ pure . surround "`" . T.pack $ sp
      , pure . surround "*" . T.strip . docToText $ view (scenarioOperation . scenarioDescription) s
      , renderSection "Introduced in solution" . renderCmdList $ M.keysSet novelCmds
      , renderSection "Referenced in description" $ renderCmdList dCmds
      ]
  surround x y = x <> y <> x

  renderSection title content =
    ["### " <> title] <> content

  firstLine =
    T.unwords
      [ "##"
      , renderTutorialTitle idx s
      ]

renderTutorialTitle :: (Show a) => a -> Scenario -> Text
renderTutorialTitle idx s =
  T.unwords
    [ T.pack $ show idx <> ":"
    , view (scenarioMetadata . scenarioName) s
    ]

linkifyCommand :: Text -> Text
linkifyCommand c = "[" <> c <> "](" <> commandsWikiAnchorPrefix <> c <> ")"

renderList :: [Text] -> [Text]
renderList items =
  if null items
    then pure "(none)"
    else map ("* " <>) items

cmdSetToSortedText :: Set Const -> [Text]
cmdSetToSortedText = sort . map (T.pack . show) . S.toList

renderCmdList :: Set Const -> [Text]
renderCmdList = renderList . map linkifyCommand . cmdSetToSortedText

-- | Generate a document which lists all the tutorial scenarios,
--   highlighting for each one which commands are introduced for the
--   first time in the canonical solution, and which commands are
--   referenced in the tutorial description.
renderTutorialProgression :: IO Text
renderTutorialProgression =
  processAndRender <$> loadScenarioCollection
 where
  processAndRender ss =
    T.unlines allLines
   where
    introSection =
      "# Command introductions by tutorial"
        : "This document indicates which tutorials introduce various commands and keywords."
        : ""
        : "All used:"
        : renderFullCmdList allUsed

    render (cmd, tut) =
      T.unwords
        [ linkifyCommand cmd
        , "(" <> renderTutorialTitle (tutIndex tut) (view getScenario $ scenarioPair tut) <> ")"
        ]
    renderFullCmdList = renderList . map render . sortOn fst
    infos = generateIntroductionsSequence ss
    allLines = introSection <> map renderUsagesMarkdown infos
    allUsed = concatMap mkTuplesForTutorial infos

    mkTuplesForTutorial tut =
      map (\x -> (T.pack $ show x, tutIdxScenario)) $
        M.keys $
          novelSolutionCommands tut
     where
      tutIdxScenario = tutInfo tut
