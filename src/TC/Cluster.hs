{-# LANGUAGE OverloadedStrings #-}

-- | The control plane state machine. Every state transition should be
-- a pure function `Cluster -> Cluster`, or `Either Text (a, Cluster)`
-- if it can be rejected.
module TC.Cluster
  ( emptyCluster,
    deadAfter,
    isAlive,
    registerNode,
    heartbeat,
    createVolume,
    deleteVolume,
    createInstance,
    deleteInstance,
    scheduleAll,
    reap,
    desiredFor,
    nodeViews,
    instanceViews,
  )
where

import Data.List (foldl', sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import TC.Net
import TC.Scheduler
import TC.Types

emptyCluster :: Cluster
emptyCluster = Cluster Map.empty Map.empty Map.empty 1

-- | A node that has not heartbeated for this amount of time is considered dead
deadAfter :: NominalDiffTime
deadAfter = 10

isAlive :: UTCTime -> Node -> Bool
isAlive now n = now `diffUTCTime` nLastSeen n < deadAfter

-- ! Nodes:

-- | Should be idempotent: re -registering a node maintains the same subnet
registerNode :: UTCTime -> NodeReg -> Cluster -> Either Text (NodeConfig, Cluster)
registerNode now r c = do
  subnet <- case Map.lookup (nrName r) (cNodes c) of
    Just old -> Right (nSubnet old)
    Nothing -> maybe (Left "no subnets available") Right (allocSubnet (map nSubnet (Map.elems (cNodes c))))
  let node =
        Node
          { nName = nrName r,
            nAddr = nrAddr r,
            nWgKey = nrWgKey r,
            nSubnet = subnet,
            nCpus = nrCpus r,
            nMemMb = nrMemMb r,
            nLastSeen = now,
            nRunning = Set.empty
          }
  pure (NodeConfig subnet, c {cNodes = Map.insert (nName node) node (cNodes c)})

-- | 'Nothing' means never observed, the agent should re-register
heartbeat :: UTCTime -> NodeId -> [InstanceId] -> Cluster -> Maybe Cluster
heartbeat now nid running c = do
  n <- Map.lookup nid (cNodes c)
  let n' = n {nLastSeen = now, nRunning = Set.fromList running}
  pure c {cNodes = Map.insert nid n' (cNodes c)}

-- ! Volumes:

createVolume :: UTCTime -> NewVolume -> Cluster -> Either Text (Volume, Cluster)
createVolume now nv c = do
  check (nvolSizeGb nv >= 1 && nvolSizeGb nv <= 100) "vol size must be in 1..100 GB"
  node <- case nvolNode nv of
    Just n
      | n `Map.member` cNodes c -> Right n
      | otherwise -> Left ("unknown node " <> unNodeId n)
    Nothing -> case sortOn volumeCount (filter (isAlive now) (Map.elems (cNodes c))) of
      [] -> Left "no live nodes"
      (n : _) -> Right (nName n)
  let vid = VolumeId ("v-" <> T.pack (show (cNextId c)))
      vol = Volume vid (nvolSizeGb nv) node
  pure (vol, c {cVolumes = Map.insert vid vol (cVolumes c), cNextId = cNextId c + 1})
  where
    volumeCount n = length [() | v <- Map.elems (cVolumes c), vNode v == nName n]

deleteVolume :: VolumeId -> Cluster -> Either Text Cluster
deleteVolume vid c
  | vid `Map.notMember` cVolumes c = Left $ "no volume " <> unVolumeId vid <> " found"
  | vid `elem` attached = Left $ "volume " <> unVolumeId vid <> " is attached to an instance"
  | otherwise = Right c {cVolumes = Map.delete vid (cVolumes c)}
  where
    attached = [vmVolume m | i <- Map.elems (cInstances c), m <- specMounts (iSpec i)]

-- ! Instances:

createInstance :: UTCTime -> InstanceSpec -> Cluster -> Either Text (Instance, Cluster)
createInstance now spec c = do
  check (specCpus spec >= 1) "instance must have at least 1 CPU"
  check (specMemMb spec >= 256) "instance must have at least 256MB memory"
  _ <- pinOf c spec
  let iid = InstanceId ("i-" <> T.pack (show (cNextId c)))
      inst = Instance iid spec Unplaced
      c1 = c {cInstances = Map.insert iid inst (cInstances c), cNextId = cNextId c + 1}
      c2 = scheduleAll now c1
  pure (fromMaybe inst (Map.lookup iid (cInstances c2)), c2)

deleteInstance :: InstanceId -> Cluster -> Maybe Cluster
deleteInstance iid c
  | iid `Map.member` cInstances c = Just c {cInstances = Map.delete iid (cInstances c)}
  | otherwise = Nothing

-- | If an instance mounts volumes, it must run where the volumes are located
-- All of its volumes must be on the same node
-- Each volume must only be mounted once
pinOf :: Cluster -> InstanceSpec -> Either Text (Maybe NodeId)
pinOf c spec = do
  let vids = map vmVolume (specMounts spec)
  check (length vids == length (dedupe vids)) "duplicate volumes in instance spec"
  vols <- mapM (\v -> maybe (Left ("No such volume " <> unVolumeId v)) Right (Map.lookup v (cVolumes c))) vids
  let others = [vmVolume m | i <- Map.elems (cInstances c), m <- specMounts (iSpec i)]
  check (all (`notElem` others) vids) "volume already attached to other instance"
  case dedupe (map vNode vols) of
    [] -> Right Nothing
    [n] -> Right (Just n)
    _ -> Left "volumes are on different nodes"
  where
    dedupe :: (Ord a) => [a] -> [a]
    dedupe = Set.toList . Set.fromList

-- ! Scheduling:

-- | Try to place every unplaced instance
scheduleAll :: UTCTime -> Cluster -> Cluster
scheduleAll now c0 = foldl' step c0 pending
  where
    pending = [i | i <- Map.elems (cInstances c0), iPlacement i == Unplaced]
    step c i = case tryPlace c i of
      Nothing -> c
      Just i' -> c {cInstances = Map.insert (iId i') i' (cInstances c)}
    tryPlace c i = do
      let pin = either (const Nothing) id (pinOf (withoutSelf c i) (iSpec i))
      nid <- place pin (iSpec i) (candidates now c)
      node <- Map.lookup nid (cNodes c)
      ip <- allocIp (nSubnet node) (usedIps c nid)
      pure i {iPlacement = Placed nid ip}
    withoutSelf c i = c {cInstances = Map.delete (iId i) (cInstances c)}

-- | Live nodes with the capacity they have left
candidates :: UTCTime -> Cluster -> [Candidate]
candidates now c =
  [ Candidate (nName n) (nCpus n - cpus) (nMemMb n - mem)
    | n <- Map.elems (cNodes c),
      isAlive now n,
      let placed = placedOn (nName n) c
          cpus = sum (map (specCpus . iSpec) placed)
          mem = sum (map (specMemMb . iSpec) placed)
  ]

placedOn :: NodeId -> Cluster -> [Instance]
placedOn nid c = [i | i <- Map.elems (cInstances c), Placed nid' _ <- [iPlacement i], nid' == nid]

usedIps :: Cluster -> NodeId -> Set IPv4
usedIps c nid = Set.fromList [ip | i <- placedOn nid c, Placed _ ip <- [iPlacement i]]

reap :: UTCTime -> Cluster -> Cluster
reap now c = scheduleAll now c {cInstances = Map.map unplacedIfLost (cInstances c)}
  where
    live = Set.fromList [nName n | n <- Map.elems (cNodes c), isAlive now n]
    unplacedIfLost i = case iPlacement i of
      Placed n _ | n `Set.notMember` live, null (specMounts (iSpec i)) -> i {iPlacement = Unplaced}
      _ -> i

-- ! Views:

-- | What a node 'should' be running
desiredFor :: NodeId -> Cluster -> Maybe Desired
desiredFor nid c = do
  _ <- Map.lookup nid (cNodes c)
  pure
    Desired
      { dInstances = Map.fromList [(iId i, DesiredInstance (iSpec i) ip) | i <- placedOn nid c, Placed _ ip <- [iPlacement i]],
        dVolumes = Map.fromList [(vId v, vSizeGb v) | v <- Map.elems (cVolumes c), vNode v == nid],
        dPeers = [Peer (nWgKey n) (nAddr n <> ":51820") (nSubnet n) | n <- Map.elems (cNodes c), nName n /= nid]
      }

nodeViews :: UTCTime -> Cluster -> [NodeView]
nodeViews now c =
  [ NodeView
      (nName n)
      (nAddr n)
      (subnetCidr (nSubnet n))
      (nCpus n)
      (nMemMb n)
      (isAlive now n)
      (length (placedOn (nName n) c))
    | n <- Map.elems (cNodes c)
  ]

-- | Running means node is alive AND its last heartbeat listed the instance
instanceViews :: UTCTime -> Cluster -> [InstanceView]
instanceViews now c = map view (Map.elems (cInstances c))
  where
    view i = InstanceView (iId i) (iSpec i) (iPlacement i) (running i)
    running i = case iPlacement i of
      Placed n _ -> case Map.lookup n (cNodes c) of
        Just node -> isAlive now node && iId i `Set.member` nRunning node
        Nothing -> False
      Unplaced -> False

-- Heplers:

check :: Bool -> Text -> Either Text ()
check ok msg = if ok then Right () else Left msg
