-- | reconcile desired actual returns list of the actions that
-- would move the node from its current state into the desired state
--
-- Its level triggered, it just always compared the two snapshots
module TC.Reconcile where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import TC.Types

data ContainerState = CRunning | CExited
  deriving (Eq, Show)

-- | what the node's current state is
data Actual = Actual
  { aContainers :: Map InstanceId ContainerState,
    aVolumes :: Set VolumeId,
    aPeers :: Map Text Peer
  }
  deriving (Eq, Show)

emptyActual :: Actual
emptyActual = Actual Map.empty Set.empty Map.empty

data Action
  = SetPeer Peer
  | RemovePeer Peer
  | EnsureVolume VolumeId Int -- create if missing, mount if unmounted, etc.
  | RemoveVolume VolumeId
  | StartContainer InstanceId DesiredInstance -- replace existing container if it exists already
  | StopContainer InstanceId
  deriving (Eq, Show)

-- | Order of actions matters. Can't mount a volume before it is created,
-- container must stop before volumes removed, etc.
reconcile :: Desired -> Actual -> [Action]
reconcile d a = peers ++ ensureVols ++ stops ++ removeVols ++ starts
  where
    peers =
      [SetPeer p | p <- dPeers d, Map.lookup (peerKey p) (aPeers a) /= Just p]
        ++ [RemovePeer p | p <- Map.elems (aPeers a), peerKey p `notElem` map peerKey (dPeers d)]

    ensureVols = [EnsureVolume v gb | (v, gb) <- Map.toList (dVolumes d), v `Set.notMember` aVolumes a]

    stops = [StopContainer i | i <- Map.keys (aContainers a), i `Map.notMember` dInstances d]

    removeVols = [RemoveVolume v | v <- Set.toList (aVolumes a), v `Map.notMember` dVolumes d]

    starts = [StartContainer i di | (i, di) <- Map.toList (dInstances d), Map.lookup i (aContainers a) /= Just CRunning]

-- | Pure model of what each action does to the world
simulate :: Action -> Actual -> Actual
simulate act a = case act of
  SetPeer p -> a {aPeers = Map.insert (peerKey p) p (aPeers a)}
  RemovePeer p -> a {aPeers = Map.delete (peerKey p) (aPeers a)}
  EnsureVolume v _ -> a {aVolumes = Set.insert v (aVolumes a)}
  RemoveVolume v -> a {aVolumes = Set.delete v (aVolumes a)}
  StartContainer i _ -> a {aContainers = Map.insert i CRunning (aContainers a)}
  StopContainer i -> a {aContainers = Map.delete i (aContainers a)}
