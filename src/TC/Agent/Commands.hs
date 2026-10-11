-- | Command lines for hte real backend as pure functions
module TC.Agent.Commands where

import Data.Text qualified as T
import TC.Net (subnetCidr)
import TC.Types

-- | Arguments to podman that (re)create an instance's container
-- mountDor says where a volume is mounted on the host
podmanRunArgs :: (VolumeId -> FilePath) -> InstanceId -> DesiredInstance -> [String]
podmanRunArgs mountDir i (DesiredInstance spec ip) =
  [ "run",
    "-d",
    "--name",
    "tc-" <> iid,
    "--label",
    "tc.managed=true",
    "--network",
    "tc0",
    "--ip",
    show ip,
    "--cpus",
    show (specCpus spec),
    "--memory",
    show (specMemMb spec) <> "m"
  ]
    ++ concat [["-v", mountDir (vmVolume m) <> ":" <> T.unpack (vmPath m)] | m <- specMounts spec]
    ++ [T.unpack (specImage spec)]
    ++ map T.unpack (specCmd spec)
  where
    iid = T.unpack (unInstanceId i)

-- | Arguments to wg that add/update a peer
wgSetPeerArgs :: Peer -> [String]
wgSetPeerArgs p =
  [ "set",
    "wg0",
    "peer",
    T.unpack (peerKey p),
    "endpoint",
    T.unpack (peerEndpoint p),
    "allowed-ips",
    T.unpack (subnetCidr (peerSubnet p)),
    "persistent-keepalive",
    "15"
  ]