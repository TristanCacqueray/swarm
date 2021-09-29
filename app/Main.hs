{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Lens                   ( (^.) )
import           Control.Monad                  ( void )
import           Control.Monad.IO.Class
import           Data.Maybe                     ( fromMaybe )
import           Data.Text                      ( Text
                                                , pack
                                                , unpack
                                                )
import qualified Data.Text.IO                  as Text
import           Language.LSP.Diagnostics
import           Language.LSP.Server
import qualified Language.LSP.Types            as J
import qualified Language.LSP.Types.Lens       as J
import           Swarm.App
import           Swarm.Language.Parse
import           Swarm.Language.Pipeline
import           System.Environment             ( getArgs )
import           System.Exit
import           System.IO                      ( stderr )

lspMain :: IO ()
lspMain = void $ runServer $ ServerDefinition
  { onConfigurationChange = const $ const $ Right ()
  , defaultConfig         = ()
  , doInitialize          = \env _req -> pure $ Right env
  , staticHandlers        = handlers
  , interpretHandler      = \env -> Iso (runLspT env) liftIO
  , options               = defaultOptions
    -- set sync options to get DidSave event
    { textDocumentSync = Just
                           (J.TextDocumentSyncOptions
                             (Just True)
                             Nothing
                             (Just False)
                             (Just False)
                             (Just $ J.InR $ J.SaveOptions $ Just True)
                           )
    }
  }
 where
  debug :: MonadIO m => Text -> m ()
  debug msg = liftIO $ Text.hPutStrLn stderr $ "[swarm-lsp] " <> msg
  sendDiagnostic :: J.NormalizedUri -> (Int, Int, Text) -> LspM () ()
  sendDiagnostic fileUri (line, column, msg) = do
    let diags =
          [ J.Diagnostic
              (J.Range (J.Position line (column - 1))
                       (J.Position line (column + 5)) -- TODO: figure out the correct end column
              )
              (Just J.DsWarning) -- severity
              Nothing -- code
              (Just "swarm-lsp") -- source
              msg
              Nothing -- tags
              (Just (J.List []))
          ]
    publishDiagnostics 100 fileUri Nothing (partitionBySource diags)

  validateSwarmCode :: J.NormalizedUri -> Text -> LspM () ()
  validateSwarmCode doc content = do
    -- debug $ "Validating: " <> pack (show doc) <> " ( " <> content <> ")"
    flushDiagnosticsBySource 1 (Just "swarm-lsp")
    let err = case readTerm' content of
          Right term -> case processParsedTerm' mempty mempty term of
            Right _ -> Nothing
            Left  e -> Just (0, 0, " " <> e)
          Left e -> Just $ showErrorPos e
    -- debug $ pack $ "-> " <> show err
    case err of
      Nothing -> pure ()
      Just e  -> sendDiagnostic doc e

  handlers :: Handlers (LspM ())
  handlers = mconcat
    [ notificationHandler J.SInitialized $ \_not -> do
      debug "Initialized"
    , notificationHandler J.STextDocumentDidSave $ \msg -> do
      let doc     = msg ^. J.params . J.textDocument . J.uri
          content = fromMaybe "?" $ msg ^. J.params . J.text
      validateSwarmCode (J.toNormalizedUri doc) content
    , notificationHandler J.STextDocumentDidOpen $ \msg -> do
      let doc     = msg ^. J.params . J.textDocument . J.uri
          content = msg ^. J.params . J.textDocument . J.text
      validateSwarmCode (J.toNormalizedUri doc) content
    ]

check :: FilePath -> IO ()
check fp = do
  content <- Text.readFile fp
  let err = case readTerm' content of
        Right term -> case processParsedTerm' mempty mempty term of
          Right _ -> Nothing
          Left  e -> Just $ " " <> unpack e
        Left e -> Just $ showShortError e
  case err of
    Nothing -> exitSuccess
    Just e  -> do
      putStrLn $ fp <> ":" <> e
      exitFailure

main :: IO ()
main = do
  args <- getArgs
  case args of
    []              -> appMain
    ["--lsp"]       -> lspMain
    ["--check", fp] -> check fp
    _               -> putStrLn "usage: swarm [--check fp]"
