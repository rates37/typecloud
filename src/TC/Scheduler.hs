module TC.Scheduler where

import Data.List (maximumBy)
import Data.Ord (Down (..), comparing)
import TC.Types

-- | A live node and the capacity it has left
data Candidate = Candidate
  { candNode :: NodeId,
    candFreeCpus :: Int,
    candFreeMemMb :: Int
  }
  deriving (Eq, Show)

-- | Choose a node for an instance
-- If a volume pins the instance to a node, only that node eligible
-- Otherwise prefer the node that would have the most memory and CPUs
-- free after placing. Tie break on node name for deterministic results.
place :: Maybe NodeId -> InstanceSpec -> [Candidate] -> Maybe NodeId
place pin spec cands =
  case filter eligible cands of
    [] -> Nothing
    xs -> Just . candNode $ maximumBy order xs
  where
    eligible c =
      maybe True (== candNode c) pin 
      && (candFreeCpus c >= specCpus spec)
      && (candFreeMemMb c >= specMemMb spec)
    leftover c = (candFreeMemMb c - specMemMb spec, candFreeCpus c - specCpus spec)
    order = comparing leftover <> comparing (Down . candNode)
