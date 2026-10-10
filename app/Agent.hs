{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, forever)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (notFound404)
import Options.Applicative
import Servant.Client
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr)
import TC.Agent.Backend
import TC.Client
import TC.Reconcile
import TC.Types

data Opts = Opts
  { server :: String,
    name :: Text,
    addr :: Text,
    cpus :: Int,
    memMb :: Int,
    dryRun :: Bool,
    stateDir :: FilePath,
    mountsFile :: FilePath
  }

opts :: Parser Opts
opts = Opts
  <$> strOption (long "server" <> value "http://localhost:8080" <> showDefault)
  <*> (T.pack <$> strOption (long "name" <> metavar "NAME" <> help "unique node name"))
  <*> (T.pack <$> strOption (long "addr" <> metavar "IP" <> help "address other nodes can reach this node at"))
  <*> option auto (long "cpus" <> value 2 <> showDefault)
  <*> option auto (long "mem-mb" <> value 2048 <> showDefault)
  <*> switch (long "dry-run" <> help "fake backend: logs actions, doesn't perform any real operations")
  <*> strOption (long "state-dir" <> value "/var/lib/typecloud" <> showDefault)
  <*> strOption (long "mounts-file" <> value "/proc/mounts" <> showDefault <> internal)

say :: String -> IO ()
say = hPutStrLn stderr

main :: IO ()
main = do
    hSetBuffering stderr LineBuffering
    o <- execParser (info (opts <**> helper) (progDesc "TypeCloud Agent"))
    backend <- if dryRun o then fakeBackend (name o) else realBackend (stateDir o) (mountsFile o)
    mgr <- newManager defaultManagerSettings
    url <- parseBaseUrl (server o)
    let env = mkClientEnv mgr url
        nid = NodeId (name o)
        call act = runClientM act env

        -- registration : retry until server is up
        register = do
            key <- bPubKey backend
            r <- call (registerC (NodeReg nid (addr o) key (cpus o) (memMb o)))
            case r of
                Right (NodeConfig subnet) -> do
                    bSetup backend subnet
                    say ("registered as " <> T.unpack (name o) <> ", subnet " <> show subnet)
                Left e -> say ("registration failed: " <> show e) >> threadDelay 2000000 >> register
        
        tick = do
            r <- call (desiredC nid)
            case r of
                Left (FailureResponse _ resp) | responseStatusCode resp == notFound404 -> register
                Left e -> say ("cannot reach control plane! (carrying on): " <> show e)
                Right desired -> do
                    actual <- bObserve backend
                    forM_ (reconcile desired actual) $ \act -> do
                        res <- try (bApply backend act) :: IO (Either SomeException ())
                        either (\e -> say ("failed! " <> show act <> ": " <> show e)) pure res
                    after <- bObserve backend
                    let running = [i | (i, CRunning) <- Map.toList (aContainers after)]
                    _ <- call (heartbeatC nid (Heartbeat running))
                    pure ()
    register
    forever $ do
        res <- try tick :: IO (Either SomeException ())
        either (\e -> say ("tick failed: " <> show e)) pure res
        threadDelay 2000000
