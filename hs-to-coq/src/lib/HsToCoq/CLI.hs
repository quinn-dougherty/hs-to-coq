{-# LANGUAGE LambdaCase, RecordWildCards,
             FlexibleContexts, UndecidableInstances,
             DeriveDataTypeable, StandaloneDeriving #-}

module HsToCoq.CLI (
  processFilesMain,
  dumpDataDecls, convertDataDecls,
  processArgs
  ) where

import Data.Foldable

import Control.Monad
import Control.Monad.IO.Class

import Data.Data

import System.Environment

import GHC
import DynFlags

import HsToCoq.Util.GHC
import HsToCoq.Util.Messages
import HsToCoq.DataDecl
import HsToCoq.ProcessFiles
import HsToCoq.ConvertData

processArgs :: GhcMonad m => m (DynFlags, [FilePath])
processArgs = do
  (dflags, files, warnings) <- join $
    parseDynamicFlagsCmdLine
      <$> getSessionDynFlags
      <*> (map (mkGeneralLocated "command line") <$> liftIO getArgs)
  printAllIfPresent unLoc "Command-line argument warning" warnings
  void $ setSessionDynFlags dflags
  pure (dflags, map unLoc files)

dumpDataDecls :: (Data a, GhcMonad m) => a -> m ()
dumpDataDecls lmod = case getDataDecls lmod :: [DataDecl' RdrName] of
  [] -> liftIO $ putStrLn "No data type declarations."
  ds -> do liftIO $ putStrLn "Data type declarations:"
           mapM_ (ghcPutPpr . fromDataDecl') ds

convertDataDecls :: (Data a, GhcMonad m) => a -> m ()
convertDataDecls lmod = case getDataDecls lmod :: [DataDecl' RdrName] of
  [] -> liftIO $ putStrLn "No data type declarations to convert."
  ds -> do liftIO $ putStrLn "Converted data type declarations:"
           mapM_ (liftIO . putStr <=< convert) ds

processFilesMain :: GhcMonad m => (Located (HsModule RdrName) -> m a) -> m ()
processFilesMain f = uncurry (traverse_ . processFile f) =<< processArgs
