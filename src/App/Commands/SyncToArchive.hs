{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module App.Commands.SyncToArchive
  ( cmdSyncToArchive
  ) where

import Antiope.Env
import App.Static
import Control.Lens
import Control.Monad
import Control.Monad.Trans.Resource
import Data.Generics.Product.Any
import Data.Semigroup                       ((<>))
import HaskellWorks.Ci.Assist.Core
import HaskellWorks.Ci.Assist.Options
import HaskellWorks.Ci.Assist.PackageConfig (templateConfig)
import HaskellWorks.Ci.Assist.Show
import HaskellWorks.Ci.Assist.Tar           (updateEntryWith)
import Options.Applicative                  hiding (columns)
import System.FilePath                      ((</>))

import qualified App.Commands.Options.Types as Z
import qualified Codec.Archive.Tar          as F
import qualified Codec.Archive.Tar.Entry    as F

import qualified Codec.Compression.GZip            as F
import qualified Control.Monad.Trans.AWS           as AWS
import qualified Data.Aeson                        as A
import qualified Data.ByteString.Lazy              as LBS
import qualified Data.ByteString.Lazy.Char8        as LBSC
import qualified Data.Text                         as T
import qualified Data.Text.IO                      as T
import qualified HaskellWorks.Ci.Assist.IO.Console as CIO
import qualified HaskellWorks.Ci.Assist.IO.Lazy    as IO
import qualified HaskellWorks.Ci.Assist.Types      as Z
import qualified System.Directory                  as IO
import qualified System.Exit                       as IO
import qualified System.IO                         as IO
import qualified System.Process                    as IO
import qualified UnliftIO.Async                    as IO

{-# ANN module ("HLint: ignore Reduce duplication"  :: String) #-}
{-# ANN module ("HLint: ignore Redundant do"        :: String) #-}

logger :: LogLevel -> LBSC.ByteString -> IO ()
logger _ _ = return ()

runSyncToArchive :: Z.SyncToArchiveOptions -> IO ()
runSyncToArchive opts = do
  let archiveUri = opts ^. the @"archiveUri"
  lbs <- LBS.readFile "dist-newstyle/cache/plan.json"
  case A.eitherDecode lbs of
    Right (planJson :: Z.PlanJson) -> do
      envAws <- mkEnv (opts ^. the @"region") logger
      let archiveCompilerUri = archiveUri <> "/" <> (planJson ^. the @"compilerId")
      IO.createLocalDirectoryIfMissing archiveCompilerUri
      let baseDir = opts ^. the @"storePath"
      packages <- getPackages baseDir planJson

      let storeCompilerPath           = baseDir <> "/" <> (planJson ^. the @"compilerId")
      let storeCompilerPackageDbPath  = storeCompilerPath <> "/package.db"

      storeCompilerPackageDbPathExists <- IO.doesDirectoryExist (T.unpack storeCompilerPackageDbPath)

      CIO.putStrLn "Checking for Package DB"

      unless storeCompilerPackageDbPathExists $ do
        CIO.putStrLn "Package DB missing.  Creating Package DB"
        hGhcPkg <- IO.spawnProcess "ghc-pkg" ["init", T.unpack storeCompilerPackageDbPath]

        exitCodeGhcPkg <- IO.waitForProcess hGhcPkg
        case exitCodeGhcPkg of
          IO.ExitFailure _ -> do
            CIO.hPutStrLn IO.stderr "ERROR: Failed to create Package DB"
            IO.exitWith (IO.ExitFailure 1)
          _ -> return ()

      CIO.putStrLn $ "Syncing " <> tshow (length packages) <> " packages"

      IO.pooledForConcurrentlyN_ (opts ^. the @"threads") packages $ \pInfo -> do
        let archiveFile = archiveUri <> "/" <> packageDir pInfo <> ".tar.gz"
        let packageStorePath = baseDir <> "/" <> packageDir pInfo
        packageStorePathExists <- IO.doesDirectoryExist (T.unpack packageStorePath)


        archiveFileExists <- runResourceT $ IO.resourceExists envAws archiveFile

        when (not archiveFileExists && packageStorePathExists) $ do
          CIO.putStrLn $ "Creating " <> archiveFile
          entries <- F.pack (T.unpack baseDir) (relativePaths pInfo)

          let entries' = case confPath pInfo of
                          Nothing   -> entries
                          Just conf -> updateEntryWith (== T.unpack conf) (templateConfig (T.unpack baseDir)) <$> entries

          IO.writeResource envAws archiveFile . F.compress . F.write $ entries

    Left errorMessage -> do
      CIO.hPutStrLn IO.stderr $ "ERROR: Unable to parse plan.json file: " <> T.pack errorMessage

  return ()

optsSyncToArchive :: Parser Z.SyncToArchiveOptions
optsSyncToArchive = Z.SyncToArchiveOptions
  <$> strOption
      (   long "archive-uri"
      <>  help "Archive URI to sync to"
      <>  metavar "S3_URI"
      <>  value (homeDirectory <> "/.cabal/archive")
      )
  <*> strOption
      (   long "store-path"
      <>  help "Path to cabal store"
      <>  metavar "DIRECTORY"
      <>  value (homeDirectory <> "/.cabal/store")
      )
  <*> option auto
      (   long "threads"
      <>  help "Number of concurrent threads"
      <>  metavar "NUM_THREADS"
      <>  value 4
      )
  <*> readOrFromTextOption
      (  long "region"
      <> short 'r'
      <> metavar "AWS_REGION"
      <> showDefault <> value Oregon
      <> help "The AWS region in which to operate"
      )

cmdSyncToArchive :: Mod CommandFields (IO ())
cmdSyncToArchive = command "sync-to-archive"  $ flip info idm $ runSyncToArchive <$> optsSyncToArchive

modifyEndpoint :: AWS.Service -> AWS.Service
modifyEndpoint s = if s ^. to AWS._svcAbbrev == "s3"
  then AWS.setEndpoint True "s3.ap-southeast-2.amazonaws.com" 443 s
  else s