{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Types for data that cross a process boundary, or is in the control plane's state
-- Includes JSON encoding/decoding for these types
module TC.Types where

import Data.Aeson
import Data.Aeson.TH (deriveJSON)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.String (IsString)
import Data.Text (Text)
import Data.Time (UTCTime)
import TC.Json (jsonOpts)
import TC.Net
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)

-- ! IDs:
newtype NodeId = NodeId {unNodeId :: Text}
  deriving stock (Show, Eq, Ord)
  deriving newtype
    ( FromJSON,
      ToJSON,
      FromJSONKey,
      ToJSONKey,
      FromHttpApiData,
      ToHttpApiData,
      IsString
    )

newtype InstanceId = InstanceId {unInstanceId :: Text}
  deriving stock (Show, Eq, Ord)
  deriving newtype
    ( FromJSON,
      ToJSON,
      FromJSONKey,
      ToJSONKey,
      FromHttpApiData,
      ToHttpApiData,
      IsString
    )

newtype VolumeId = VolumeId {unVolumeId :: Text}
  deriving stock (Show, Eq, Ord)
  deriving newtype
    ( FromJSON,
      ToJSON,
      FromJSONKey,
      ToJSONKey,
      FromHttpApiData,
      ToHttpApiData,
      IsString
    )

-- ! User facing specs:

data VolumeMount = VolumeMount {vmVolume :: VolumeId, vmPath :: Text}
  deriving (Eq, Show)

data InstanceSpec = InstanceSpec
  { specImage :: Text,
    specCmd :: [Text],
    specCpus :: Int,
    specMemMb :: Int,
    specMounts :: [VolumeMount]
  }
  deriving (Eq, Show)

data Placement = Unplaced | Placed NodeId IPv4
  deriving (Eq, Show)

instance ToJSON Placement where
  toJSON Unplaced = Null
  toJSON (Placed n i) = object ["node" .= n, "ip" .= i]

instance FromJSON Placement where
  parseJSON Null = pure Unplaced
  parseJSON v = withObject "Placement" (\o -> Placed <$> o .: "node" <*> o .: "ip") v

-- ! Control Plane State:

data Instance = Instance
  { iId :: InstanceId,
    iSpec :: InstanceSpec,
    iPlacement :: Placement
  }
  deriving (Eq, Show)

data Volume = Volume
  { vId :: VolumeId,
    vSizeGb :: Int,
    vNode :: NodeId
  }
  deriving (Eq, Show)

data Node = Node
  { nName :: NodeId,
    nAddr :: Text, -- underlay address other nodes use for wireguard
    nWgKey :: Text, -- wg public key
    nSubnet :: SubnetId,
    nCpus :: Int,
    nMemMb :: Int,
    nLastSeen :: UTCTime,
    nRunning :: Set InstanceId -- what the node's agent last reported
  }
  deriving (Eq, Show)

data Cluster = Cluster
  { cNodes :: Map NodeId Node,
    cInstances :: Map InstanceId Instance,
    cVolumes :: Map VolumeId Volume,
    cNextId :: Int
  }
  deriving (Eq, Show)

-- ! Node <--> Server:

data NodeReg = NodeReg
  { nrName :: NodeId,
    nrAddr :: Text,
    nrWgKey :: Text,
    nrCpus :: Int,
    nrMemMb :: Int
  }
  deriving (Eq, Show)

newtype NodeConfig = NodeConfig {ncSubnet :: SubnetId}
  deriving (Eq, Show)

newtype Heartbeat = Heartbeat {hbRunning :: [InstanceId]}
  deriving (Eq, Show)

data Peer = Peer
  { peerKey :: Text,
    peerEndpoint :: Text, -- the ip:port of the peer's wg socket
    peerSubnet :: SubnetId
  }
  deriving (Eq, Show)

data DesiredInstance = DesiredInstance
  { diSpec :: InstanceSpec,
    diIp :: IPv4
  }
  deriving (Eq, Show)

-- everything the node should be doing/running/storing
data Desired = Desired
  { dInstances :: Map InstanceId DesiredInstance,
    dVolumes :: Map VolumeId Int,
    dPeers :: [Peer]
  }
  deriving (Eq, Show)

-- ! User facing:
data NewVolume = NewVolume
  { nvolSizeGb :: Int,
    nvolNode :: Maybe NodeId
  }
  deriving (Eq, Show)

data NodeView = NodeView
  { nviewName :: NodeId,
    nviewAddr :: Text,
    nviewSubnet :: Text,
    nviewCpus :: Int,
    nviewMemMb :: Int,
    nviewAlice :: Bool,
    nviewInstnaces :: Int
  }
  deriving (Eq, Show)

data InstanceView = InstanceView
  { iviewId :: InstanceId,
    iviewSpec :: InstanceSpec,
    iviewPlacement :: Placement,
    iviewRunning :: Bool
  }
  deriving (Eq, Show)

-- generate ToJSON and FromJSON instances templates:
deriveJSON jsonOpts ''VolumeMount
deriveJSON jsonOpts ''InstanceSpec
deriveJSON jsonOpts ''Instance
deriveJSON jsonOpts ''Volume
deriveJSON jsonOpts ''Node
deriveJSON jsonOpts ''Cluster
deriveJSON jsonOpts ''NodeReg
deriveJSON jsonOpts ''NodeConfig
deriveJSON jsonOpts ''Heartbeat
deriveJSON jsonOpts ''Peer
deriveJSON jsonOpts ''DesiredInstance
deriveJSON jsonOpts ''Desired
deriveJSON jsonOpts ''NewVolume
deriveJSON jsonOpts ''NodeView
deriveJSON jsonOpts ''InstanceView
