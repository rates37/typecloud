{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | readBackend shells out to podman, wg, ip, mount (need root)
-- fakeBackend simulates and logs the activity without actually performing it
module TC.Agent.Backend where

import Control.Exception (throwIO)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (hPutStrLn, stderr)
import TC.Net
import TC.Reconcile

data Backend = Backend
  { bPubKey :: IO Text, -- this node's wg key
    bSetup :: SubnetId -> IO (), -- one time, idempotent
    bObserve :: IO Actual,
    bApply :: Action -> IO ()
  }

-- ! Fake Backend

fakeBackend :: Text -> IO Backend
fakeBackend name = do
  ref <- newIORef emptyActual
  pure
    Backend
      { bPubKey = pure ("fakekey-" <> name <> "="),
        bSetup = \s -> logLine ("[fakeBackend] setup subnet " <> T.unpack (subnetCidr s)),
        bObserve = readIORef ref,
        bApply = \a -> do
          logLine ("[fakeBackend] apply " <> show a)
          modifyIORef' ref (simulate a)
      }

logLine :: String -> IO ()
logLine = hPutStrLn stderr

-- ! Real Backend
-- TODO
realBackend :: FilePath -> FilePath -> IO Backend
realBackend base mountsFile = do
  logLine "ayo ts not ready yet"
  pure
    Backend
      { bPubKey = throwIO (userError "not implemented"),
        bSetup = \_ -> throwIO (userError "not implemented"),
        bObserve = throwIO (userError "not implemented"),
        bApply = \_ -> throwIO (userError "not implemented")
      }
