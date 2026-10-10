module TC.Client where

import Servant.API
import Servant.Client
import TC.API
import TC.Types

registerC :: NodeReg -> ClientM NodeConfig
listNodesC :: ClientM [NodeView]
desiredC :: NodeId -> ClientM Desired
heartbeatC :: NodeId -> Heartbeat -> ClientM NoContent
createInstanceC :: InstanceSpec -> ClientM InstanceView
listInstancesC :: ClientM [InstanceView]
deleteInstanceC :: InstanceId -> ClientM NoContent
createVolumeC :: NewVolume -> ClientM Volume
listVolumesC :: ClientM [Volume]
deleteVolumeC :: VolumeId -> ClientM NoContent
registerC :<|> listNodesC :<|> desiredC :<|> heartbeatC
  :<|> createInstanceC
  :<|> listInstancesC
  :<|> deleteInstanceC
  :<|> createVolumeC
  :<|> listVolumesC
  :<|> deleteVolumeC = client api
