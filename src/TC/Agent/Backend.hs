{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | readBackend shells out to podman, wg, ip, mount (need root)
-- fakeBackend simulates and logs the activity without actually performing it
module TC.Agent.Backend where

import Control.Exception (throwIO)
import Control.Monad (unless, void, when)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import System.Directory
import System.IO (hPutStrLn, stderr)
import System.Process.Typed
import TC.Agent.Commands
import TC.Agent.Parse
import TC.Net
import TC.Reconcile
import TC.Types

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

-- | realBackend: all node -local state lives under `base`
-- mountsFile is where to read the mount table (e.g., "/proc/mounts")
realBackend :: FilePath -> FilePath -> IO Backend
realBackend base mountsFile = do
  let volDir = base <> "/volumes"
      mntDir = base <> "/mnt"
      keyFile = base <> "/wg.key"
      img v = volDir <> "/" <> T.unpack (unVolumeId v) <> ".img"
      mnt v = mntDir <> "/" <> T.unpack (unVolumeId v)
      cname i = "tc-" <> T.unpack (unInstanceId i)
  mapM_ (createDirectoryIfMissing True) [base, volDir, mntDir]

  let pubKey = do
        have <- doesFileExist keyFile
        unless have $ do
          k <- sh "wg" ["genkey"] Nothing
          writeFile keyFile k
        priv <- readFile keyFile
        T.strip . T.pack <$> sh "wg" ["pubkey"] (Just priv)

      setup subnet = do
        let cidr = T.unpack (subnetCidr subnet)
            gw = show (gatewayIp subnet)
        void (sh "sysctl" ["-w", "net.ipv4.ip_forward=1"] Nothing)
        shIgnore "ip" ["link", "add", "wg0", "type", "wireguard"]
        void (sh "wg" ["set", "wg0", "listen-port", "51820", "private-key", keyFile] Nothing)
        void (sh "ip" ["link", "set", "wg0", "up"] Nothing)
        shIgnore "podman" ["network", "create", "--subnet", cidr, "--gateway", gw, "tc0"]
        -- Netavark (podman network backend) masks traffic leaving the bridge, but
        -- overlay-to-overlay traffic must keep its source address so exempt it
        let nat = ["-t", "nat", "POSTROUTING", "-s", "10.100.0.0/16", "-d", "10.100.0.0/16", "-j", "ACCEPT"]
        (c, _, _) <- readProcess (proc "iptables" ("-t" : "nat" : "-C" : drop 2 nat))
        when (c /= ExitSuccess) $ shIgnore "iptables" ("-t" : "nat" : "-I" : drop 2 nat)

      observe = do
        ps <-
          sh
            "podman"
            [ "ps",
              "-a",
              "--filter",
              "label=tc.managed=true",
              "--format",
              "{{.Names}} {{.State}}"
            ]
            Nothing
        wg <- readOrEmpty "wg" ["show", "wg0", "dump"]
        mounts <- readFile mountsFile
        pure
          Actual
            { aContainers = parsePs (T.pack ps),
              aVolumes = parseMounts mntDir (T.pack mounts),
              aPeers = parseWgDump (T.pack wg)
            }

      apply = \case
        SetPeer p -> do
          let cidr = T.unpack (subnetCidr (peerSubnet p))
          void (sh "wg" (wgSetPeerArgs p) Nothing)
          void (sh "ip" ["route", "replace", cidr, "dev", "wg0"] Nothing)
        RemovePeer p -> do
          void (sh "wg" ["set", "wg0", "peer", T.unpack (peerKey p), "remove"] Nothing)
          shIgnore "ip" ["route", "del", T.unpack (subnetCidr (peerSubnet p)), "dev", "wg0"]
        EnsureVolume v gb -> do
          exists <- doesFileExist (img v)
          unless exists $ do
            -- build under a temp name and rename
            void (sh "truncate" ["-s", show gb <> "G", img v <> ".tmp"] Nothing)
            void (sh "mkfs.ext4" ["-q", "-F", img v <> ".tmp"] Nothing)
            renameFile (img v <> ".tmp") (img v)
          createDirectoryIfMissing True (mnt v)
          (c, _, _) <- readProcess (proc "mountpoint" ["-q", mnt v])
          when (c /= ExitSuccess) $ void (sh "mount" ["-o", "loop", img v, mnt v] Nothing)
        RemoveVolume v -> do
          void (sh "umount" [mnt v] Nothing)
          removeFile (img v)
          removeDirectory (mnt v)
        -- "-t 0": skip podman's 10s SIGTERM grace period, it would block the agent
        -- loop (no heartbeats) long enough for the server to declare the node dead
        StopContainer i -> void (sh "podman" ["rm", "-f", "-t", "0", cname i] Nothing)
        StartContainer i di -> do
          shIgnore "podman" ["rm", "-f", "-t", "0", cname i] -- see StopContainer
          void (sh "podman" (podmanRunArgs mnt i di) Nothing)

  pure Backend {bPubKey = pubKey, bSetup = setup, bObserve = observe, bApply = apply}

-- helpers:

-- | Run a command, return stdout, throw on failure
sh :: String -> [String] -> Maybe String -> IO String
sh cmd args input = do
  let cfg =
        maybe
          id
          (setStdin . byteStringInput . BL.fromStrict . TE.encodeUtf8 . T.pack)
          input
          (proc cmd args)
  (code, out, err) <- readProcess cfg
  case code of
    ExitSuccess -> pure (TL.unpack (TLE.decodeUtf8 out))
    ExitFailure n ->
      throwIO . userError $
        unwords (cmd : args) <> " exited " <> show n <> ": " <> TL.unpack (TLE.decodeUtf8 err)

-- | Run a command ignoring failure (for errors like "already exists")
shIgnore :: String -> [String] -> IO ()
shIgnore cmd args = void (readProcess (proc cmd args))

-- | like `sh` but a failure yields (e.g., wg0 not up yet)
readOrEmpty :: String -> [String] -> IO String
readOrEmpty cmd args = do
  (code, out, _) <- readProcess (proc cmd args)
  pure (if code == ExitSuccess then TL.unpack (TLE.decodeUtf8 out) else "")
