{-# LANGUAGE LambdaCase #-}

module TC.Client where

import Control.Exception (fromException)
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Text qualified as T
import Network.HTTP.Client (HttpException (..))
import Network.HTTP.Types (statusCode)
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

-- | Better description of a client error. Otherwise `show` on a ConnectionError
-- will dump the entire http-client request which is too verbose and not useful
describeClientError :: ClientError -> String
describeClientError = \case
  FailureResponse _ r -> "HTTP " <> show (statusCode (responseStatusCode r)) <> ": " <> BL.unpack (responseBody r)
  ConnectionError se -> case fromException se of
    Just (HttpExceptionRequest _ c) -> "cannot connect: " <> show c
    _ -> "cannot connect: " <> show se
  DecodeFailure msg _ -> "unexpected response: " <> T.unpack msg
  e -> show e
