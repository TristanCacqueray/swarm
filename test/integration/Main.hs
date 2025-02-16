{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Swarm integration tests
module Main where

import Control.Lens (Ixed (ix), to, use, view, (&), (.~), (<&>), (^.), (^?!))
import Control.Monad (filterM, forM_, unless, void, when)
import Control.Monad.State (StateT (runStateT), gets)
import Control.Monad.Trans.Except (runExceptT)
import Data.Char (isSpace)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (Foldable (toList), find)
import Data.IntSet qualified as IS
import Data.Map qualified as M
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Yaml (ParseException, prettyPrintParseException)
import Swarm.DocGen (EditorType (..))
import Swarm.DocGen qualified as DocGen
import Swarm.Game.CESK (emptyStore, initMachine)
import Swarm.Game.Entity (EntityMap, loadEntities)
import Swarm.Game.Robot (defReqs, leText, machine, robotContext, robotLog, waitingUntil)
import Swarm.Game.Scenario (Scenario)
import Swarm.Game.State (
  GameState,
  WinCondition (Won),
  activeRobots,
  baseRobot,
  initGameStateForScenario,
  messageQueue,
  robotMap,
  ticks,
  waitingRobots,
  winCondition,
  winSolution,
 )
import Swarm.Game.Step (gameTick)
import Swarm.Language.Context qualified as Ctx
import Swarm.Language.Pipeline (ProcessedTerm (..), processTerm)
import Swarm.Util.Yaml (decodeFileEitherE)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getEnvironment)
import System.FilePath.Posix (takeExtension, (</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.ExpectedFailure (expectFailBecause)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)
import Witch (into)

main :: IO ()
main = do
  examplePaths <- acquire "example" "sw"
  scenarioPaths <- acquire "data/scenarios" "yaml"
  scenarioPrograms <- acquire "data/scenarios" "sw"
  ci <- any (("CI" ==) . fst) <$> getEnvironment
  entities <- loadEntities
  case entities of
    Left t -> fail $ "Couldn't load entities: " <> into @String t
    Right em -> do
      defaultMain $
        testGroup
          "Tests"
          [ exampleTests examplePaths
          , exampleTests scenarioPrograms
          , scenarioTests em scenarioPaths
          , testScenarioSolution ci em
          , testEditorFiles
          ]

exampleTests :: [(FilePath, String)] -> TestTree
exampleTests inputs = testGroup "Test example" (map exampleTest inputs)

exampleTest :: (FilePath, String) -> TestTree
exampleTest (path, fileContent) =
  testCase ("processTerm for contents of " ++ show path) $ do
    either (assertFailure . into @String) (const . return $ ()) value
 where
  value = processTerm $ into @Text fileContent

scenarioTests :: EntityMap -> [(FilePath, String)] -> TestTree
scenarioTests em inputs = testGroup "Test scenarios" (map (scenarioTest em) inputs)

scenarioTest :: EntityMap -> (FilePath, String) -> TestTree
scenarioTest em (path, _) =
  testCase ("parse scenario " ++ show path) (void $ getScenario em path)

getScenario :: EntityMap -> FilePath -> IO Scenario
getScenario em p = do
  res <- decodeFileEitherE em p :: IO (Either ParseException Scenario)
  case res of
    Left err -> assertFailure (prettyPrintParseException err)
    Right s -> return s

acquire :: FilePath -> String -> IO [(FilePath, String)]
acquire dir ext = do
  paths <- listDirectory dir <&> map (dir </>)
  filePaths <- filterM (\path -> doesFileExist path <&> (&&) (hasExt path)) paths
  children <- mapM (\path -> (,) path <$> readFile path) filePaths
  -- recurse
  sub <- filterM doesDirectoryExist paths
  transChildren <- concat <$> mapM (`acquire` ext) sub
  return $ children <> transChildren
 where
  hasExt path = takeExtension path == ("." ++ ext)

data Time
  = -- | One second should be enough to run most programs.
    Default
  | -- | You can specify more seconds if you need to.
    Sec Int
  | -- | If you absolutely have to, you can ignore timeout.
    None

time :: Time -> Int
time = \case
  Default -> 1 * sec
  Sec s -> s * sec
  None -> -1
 where
  sec :: Int
  sec = 10 ^ (6 :: Int)

testScenarioSolution :: Bool -> EntityMap -> TestTree
testScenarioSolution _ci _em =
  testGroup
    "Test scenario solutions"
    [ testGroup
        "Tutorial"
        [ testSolution Default "Tutorials/backstory"
        , testSolution (Sec 3) "Tutorials/move"
        , testSolution Default "Tutorials/craft"
        , testSolution Default "Tutorials/grab"
        , testSolution Default "Tutorials/place"
        , testSolution Default "Tutorials/types"
        , testSolution Default "Tutorials/type-errors"
        , testSolution Default "Tutorials/install"
        , testSolution Default "Tutorials/build"
        , testSolution Default "Tutorials/bind2"
        , testSolution' Default "Tutorials/crash" $ \g -> do
            let rs = toList $ g ^. robotMap
            let hints = any (T.isInfixOf "you will win" . view leText) . toList . view robotLog
            let win = isJust $ find hints rs
            assertBool "Could not find a robot with winning instructions!" win
        , testSolution Default "Tutorials/scan"
        , testSolution Default "Tutorials/def"
        , testSolution Default "Tutorials/lambda"
        , testSolution Default "Tutorials/require"
        , testSolution Default "Tutorials/requireinv"
        , testSolution Default "Tutorials/conditionals"
        , testSolution (Sec 5) "Tutorials/farming"
        ]
    , testGroup
        "Challenges"
        [ testSolution Default "Challenges/chess_horse"
        , testSolution Default "Challenges/teleport"
        , testSolution (Sec 5) "Challenges/2048"
        , testSolution (Sec 10) "Challenges/hanoi"
        , testGroup
            "Mazes"
            [ testSolution Default "Challenges/Mazes/easy_cave_maze"
            , testSolution Default "Challenges/Mazes/easy_spiral_maze"
            , testSolution Default "Challenges/Mazes/invisible_maze"
            , testSolution Default "Challenges/Mazes/loopy_maze"
            ]
        , testGroup
            "Ranching"
            [ testSolution (Sec 30) "Challenges/Ranching/gated-paddock"
            ]
        ]
    , testGroup
        "Regression tests"
        [ testSolution Default "Testing/394-build-drill"
        , testSolution Default "Testing/373-drill"
        , testSolution Default "Testing/428-drowning-destroy"
        , testSolution' Default "Testing/475-wait-one" $ \g -> do
            let t = g ^. ticks
                r1Waits = g ^?! robotMap . ix 1 . to waitingUntil
                active = IS.member 1 $ g ^. activeRobots
                waiting = elem 1 . concat . M.elems $ g ^. waitingRobots
            assertBool "The game should only take one tick" $ t == 1
            assertBool "Robot 1 should have waiting machine" $ isJust r1Waits
            assertBool "Robot 1 should be still active" active
            assertBool "Robot 1 should not be in waiting set" $ not waiting
        , testSolution Default "Testing/490-harvest"
        , testSolution Default "Testing/504-teleport-self"
        , testSolution Default "Testing/508-capability-subset"
        , testGroup
            "Possession criteria (#858)"
            [ testSolution Default "Testing/858-inventory/858-possession-objective"
            , expectFailBecause "Known bug #858" $
                testSolution Default "Testing/858-inventory/858-counting-objective"
            ]
        , testGroup
            "Require (#201)"
            [ testSolution Default "Testing/201-require/201-require-device"
            , testSolution Default "Testing/201-require/201-require-device-creative"
            , testSolution Default "Testing/201-require/201-require-device-creative1"
            , testSolution Default "Testing/201-require/201-require-entities"
            , testSolution Default "Testing/201-require/201-require-entities-def"
            , testSolution Default "Testing/201-require/533-reprogram-simple"
            , testSolution Default "Testing/201-require/533-reprogram"
            ]
        , testSolution Default "Testing/479-atomic-race"
        , testSolution (Sec 5) "Testing/479-atomic"
        , testSolution Default "Testing/555-teleport-location"
        , testSolution Default "Testing/562-lodestone"
        , testSolution Default "Testing/378-objectives"
        , testSolution Default "Testing/684-swap"
        , testSolution Default "Testing/699-movement-fail/699-move-blocked"
        , testSolution Default "Testing/699-movement-fail/699-move-liquid"
        , testSolution Default "Testing/699-movement-fail/699-teleport-blocked"
        , testSolution Default "Testing/710-multi-robot"
        ]
    ]
 where
  -- expectFailIf :: Bool -> String -> TestTree -> TestTree
  -- expectFailIf b = if b then expectFailBecause else (\_ x -> x)

  testSolution :: Time -> FilePath -> TestTree
  testSolution s p = testSolution' s p (const $ pure ())

  testSolution' :: Time -> FilePath -> (GameState -> Assertion) -> TestTree
  testSolution' s p verify = testCase p $ do
    out <- runExceptT $ initGameStateForScenario p Nothing Nothing
    case out of
      Left x -> assertFailure $ unwords ["Failure in initGameStateForScenario:", T.unpack x]
      Right gs -> case gs ^. winSolution of
        Nothing -> assertFailure "No solution to test!"
        Just sol@(ProcessedTerm _ _ _ reqCtx) -> do
          let gs' =
                gs
                  -- See #827 for an explanation of why it's important to set
                  -- the robotContext defReqs here (and also why this will,
                  -- hopefully, eventually, go away).
                  & baseRobot . robotContext . defReqs .~ reqCtx
                  & baseRobot . machine .~ initMachine sol Ctx.empty emptyStore
          m <- timeout (time s) (snd <$> runStateT playUntilWin gs')
          case m of
            Nothing -> assertFailure "Timed out - this likely means that the solution did not work."
            Just g -> do
              -- When debugging, try logging all robot messages.
              -- printAllLogs
              noBadErrors g
              verify g

  playUntilWin :: StateT GameState IO ()
  playUntilWin = do
    w <- use winCondition
    b <- gets badErrorsInLogs
    when (null b) $ case w of
      Won _ -> return ()
      _ -> gameTick >> playUntilWin

noBadErrors :: GameState -> Assertion
noBadErrors g = do
  let bad = badErrorsInLogs g
  unless (null bad) (assertFailure . T.unpack . T.unlines . take 5 $ nubOrd bad)

badErrorsInLogs :: GameState -> [Text]
badErrorsInLogs g =
  concatMap
    (\r -> filter isBad (seqToTexts $ r ^. robotLog))
    (g ^. robotMap)
    <> filter isBad (seqToTexts $ g ^. messageQueue)
 where
  seqToTexts = map (view leText) . toList
  isBad m = "Fatal error:" `T.isInfixOf` m || "swarm/issues" `T.isInfixOf` m

printAllLogs :: GameState -> IO ()
printAllLogs g =
  mapM_
    (\r -> forM_ (r ^. robotLog) (putStrLn . T.unpack . view leText))
    (g ^. robotMap)

-- | Test that editor files are up-to-date.
testEditorFiles :: TestTree
testEditorFiles =
  testGroup
    "editors"
    [ testGroup
        "VS Code"
        [ testTextInVSCode "operators" (const DocGen.operatorNames)
        , testTextInVSCode "builtin" DocGen.builtinFunctionList
        , testTextInVSCode "commands" DocGen.keywordsCommands
        , testTextInVSCode "directions" DocGen.keywordsDirections
        ]
    , testGroup
        "Emacs"
        [ testTextInEmacs "builtin" DocGen.builtinFunctionList
        , testTextInEmacs "commands" DocGen.keywordsCommands
        , testTextInEmacs "directions" DocGen.keywordsDirections
        ]
    ]
 where
  testTextInVSCode name tf = testTextInFile False name (tf VSCode) "editors/vscode/syntaxes/swarm.tmLanguage.json"
  testTextInEmacs name tf = testTextInFile True name (tf Emacs) "editors/emacs/swarm-mode.el"
  testTextInFile :: Bool -> String -> Text -> FilePath -> TestTree
  testTextInFile whitespace name t fp = testCase name $ do
    let removeLW' = T.unlines . map (T.dropWhile isSpace) . T.lines
        removeLW = if whitespace then removeLW' else id
    f <- T.readFile fp
    assertBool
      ( "EDITOR FILE IS NOT UP TO DATE!\n"
          <> "I could not find the text:\n"
          <> T.unpack t
          <> "\nin file "
          <> fp
      )
      (removeLW t `T.isInfixOf` removeLW f)
