{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

-- | The HTTP API surface for the control plane. Server implements the API
-- and the agent + CLI get clients derived from it.

module TC.API (API, api) where

import Data.Proxy (Proxy (..))
import Servant.API
import TC.Types

type API =
  -- node agents
  "nodes" :> ReqBody '[JSON] NodeReg :> Post '[JSON] NodeConfig
    :<|> "nodes" :> Get '[JSON] [NodeView]
    :<|> "nodes" :> Capture "name" NodeId :> "desired" :> Get '[JSON] Desired
    :<|> "nodes" :> Capture "name" NodeId :> "heartbeat" :> ReqBody '[JSON] Heartbeat :> PostNoContent
    -- instances (compute)
    :<|> "instances" :> ReqBody '[JSON] InstanceSpec :> Post '[JSON] InstanceView
    :<|> "instances" :> Get '[JSON] [InstanceView]
    :<|> "instances" :> Capture "id" InstanceId :> DeleteNoContent
    -- volumes (storage)
    :<|> "volumes" :> ReqBody '[JSON] NewVolume :> Post '[JSON] Volume
    :<|> "volumes" :> Get '[JSON] [Volume]
    :<|> "volumes" :> Capture "id" VolumeId :> DeleteNoContent

api :: Proxy API
api = Proxy