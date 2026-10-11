{-# LANGUAGE OverloadedStrings #-}

-- | Parser utilities for text that podman, wg, kernel, etc. return
module TC.Agent.Parse (parsePs, parseWgDump, parseMounts) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import TC.Net (parseCidr24)
import TC.Reconcile
import TC.Types

-- | Output of podman ps -a --filter label=tc.managed=true --format "{{.Names}} {{.State}}"
-- containers are named `tc-<instance id>`
parsePs :: Text -> Map InstanceId ContainerState
parsePs t = Map.fromList (mapMaybe line (T.lines t))
  where
    line l = case T.words l of
      [name, st]
        | Just iid <- T.stripPrefix "tc-" name ->
            Just (InstanceId iid, if st == "running" then CRunning else CExited)
      _ -> Nothing

-- | Output of `wg show wg0 dump`
-- First line describes the interface, each further line is a peer:
-- pubKey, psk, endpoint, allowed-ips, handshake, rx, tx, keepalive
-- tab separated^
parseWgDump :: Text -> Map Text Peer
parseWgDump t = Map.fromList (mapMaybe peer (drop 1 (T.lines t)))
  where
    peer l = case T.splitOn "\t" l of
      (key : _psk : endpoint : allowed : _) -> do
        subnet <- parseCidr24 (T.takeWhile (/= ',') allowed)
        pure (key, Peer key endpoint subnet)
      _ -> Nothing

-- | Contents of /proc/mounts
-- Volumes are mounted at root/<volume id>
parseMounts :: FilePath -> Text -> Set VolumeId
parseMounts root t = Set.fromList (mapMaybe line (T.lines t))
  where
    prefix = T.pack root <> "/"
    line l = case T.words l of
      (_dev : mnt : _) -> VolumeId <$> T.stripPrefix prefix mnt
      _ -> Nothing
