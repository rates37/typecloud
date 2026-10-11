{-# LANGUAGE OverloadedStrings #-}

-- | Control plane is a single Servant server wrapping a `MVar Cluster`
-- Every handler accquires the lock and applies the pure transition from
-- TC.Cluster
module TC.Server (Env, newEnv, application, reaperLoop) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeFileStrict, encode)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import Servant
import System.Directory (doesFileExist, renameFile)
import TC.API
import TC.Cluster
import TC.Types

data Env = Env
  { envState :: MVar Cluster,
    envSnapshot :: Maybe FilePath
  }

-- | Load the snapshot if there is one
-- Heartbeat times are not persisted meaningfully
newEnv :: Maybe FilePath -> IO Env
newEnv snap = do
  now <- getCurrentTime
  c <- case snap of
    Nothing -> pure emptyCluster
    Just f -> do
      exists <- doesFileExist f
      if not exists
        then pure emptyCluster
        else
          eitherDecodeFileStrict f >>= \r -> case r of
            Left e -> fail ("invalid or corrupt snapshot" <> f <> ": " <> e)
            Right c0 -> pure c0 {cNodes = Map.map (\n -> n {nLastSeen = now}) (cNodes c0)}
  Env <$> newMVar c <*> pure snap

save :: Env -> Cluster -> IO ()
save env c = case envSnapshot env of
  Nothing -> pure ()
  Just f -> do
    BL.writeFile (f <> ".tmp") (encode c)
    renameFile (f <> ".tmp") f -- ensures the file is written atomically to never corrupt it

-- | Run a pure transition under the lock 'Left' becomes HTTP 400
mutate :: Env -> Bool -> (UTCTime -> Cluster -> Either Text (a, Cluster)) -> Handler a
mutate env persist f = do
  now <- liftIO getCurrentTime
  r <- liftIO . modifyMVar (envState env) $ \c -> case f now c of
    Left e -> pure (c, Left e)
    Right (a, c') -> do
      if persist then save env c' else pure ()
      pure (c', Right a)
  either (throwError . bad) pure r
  where
    bad e = err400 {errBody = BL.fromStrict (TE.encodeUtf8 e)}

query :: Env -> (UTCTime -> Cluster -> a) -> Handler a
query env f = liftIO $ do
  now <- getCurrentTime
  f now <$> readMVar (envState env)

handlers :: Env -> Server API
handlers env =
  registerH
    :<|> listNodesH
    :<|> desiredH
    :<|> heartbeatH
    :<|> createInstanceH
    :<|> listInstancesH
    :<|> deleteInstanceH
    :<|> createVolumeH
    :<|> listVolumesH
    :<|> deleteVolumeH
  where
    registerH r = mutate env True (\now c -> registerNode now r c)

    listNodesH = query env nodeViews

    desiredH nid = query env (\_ -> desiredFor nid) >>= maybe (throwError err404) pure

    heartbeatH nid (Heartbeat running) = do
      -- Not persisted to disk as it happens every couple of seconds per node and adds nothing meaningful
      r <- liftIO $ do
        now <- getCurrentTime
        modifyMVar (envState env) $ \c -> pure $ case heartbeat now nid running c of
          Nothing -> (c, False)
          Just c' -> (c', True)
      if r then pure NoContent else throwError err404

    createInstanceH spec = do
      i <- mutate env True (\now c -> createInstance now spec c)
      pure (InstanceView (iId i) (iSpec i) (iPlacement i) False) -- can't be running yet
    listInstancesH = query env instanceViews

    deleteInstanceH iid = do
      r <- liftIO . modifyMVar (envState env) $ \c -> case deleteInstance iid c of
        Nothing -> pure (c, False)
        Just c' -> save env c' >> pure (c', True)
      if r then pure NoContent else throwError err404 {errBody = BL.fromStrict (TE.encodeUtf8 ("no instance " <> unInstanceId iid <> " found"))}

    createVolumeH nv = mutate env True (\now c -> createVolume now nv c)
    listVolumesH = query env (\_ c -> Map.elems (cVolumes c))
    deleteVolumeH vid = mutate env True (\_ c -> (\c' -> (NoContent, c')) <$> deleteVolume vid c)

application :: Env -> Application
application = serve api . handlers

-- | Every 2s: mark dead nodes' stateless instances for re-scheduling
-- and place anything that's still pending
reaperLoop :: Env -> IO ()
reaperLoop env = forever $ do
  threadDelay 2000000
  now <- getCurrentTime
  void . modifyMVar (envState env) $ \c -> do
    let c' = reap now c
    if c' /= c then save env c' else pure ()
    pure (c', ())
