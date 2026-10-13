{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.ByteString.Lazy.Char8 qualified as BL
import Data.List (transpose)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative
import Servant.Client
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import TC.Client
import TC.Net (renderIPv4)
import TC.Types

data Cmd
  = Nodes
  | Ps
  | Run InstanceSpec
  | Rm InstanceId
  | VolCreate Int (Maybe NodeId)
  | VolLs
  | VolRm VolumeId

cmd :: Parser Cmd
cmd =
  hsubparser $
    command "nodes" (info (pure Nodes) (progDesc "list nodes"))
      <> command "ps" (info (pure Ps) (progDesc "list instances"))
      <> command "run" (info (Run <$> spec) (progDesc "start an instance"))
      <> command "rm" (info (Rm . InstanceId . T.pack <$> argument str (metavar "ID")) (progDesc "delete an instance"))
      <> command
        "volume-create"
        ( info
            ( VolCreate
                <$> argument auto (metavar "GB")
                <*> optional (NodeId . T.pack <$> strOption (long "node"))
            )
            (progDesc "create a volume")
        )
      <> command "volume-ls" (info (pure VolLs) (progDesc "list volumes"))
      <> command "volume-rm" (info (VolRm . VolumeId . T.pack <$> argument str (metavar "ID")) (progDesc "delete a volume"))
  where
    spec =
      InstanceSpec
        <$> (T.pack <$> argument str (metavar "IMAGE"))
        <*> (map T.pack <$> many (argument str (metavar "CMD...")))
        <*> option auto (long "cpus" <> value 1 <> showDefault)
        <*> option auto (long "mem" <> value 256 <> showDefault <> help "MB")
        <*> many (option mount (long "volume" <> short 'v' <> metavar "VOL:PATH"))
    mount = eitherReader $ \s -> case break (== ':') s of
      (v, ':' : p@(_ : _)) -> Right (VolumeMount (VolumeId (T.pack v)) (T.pack p))
      _ -> Left "expected VOL:PATH"

-- | Lay rows out as aligned columns. Each column is as wide as its longest
-- cell and trailing padding is dropped
table :: [[T.Text]] -> [T.Text]
table rows = map line rows
  where
    widths = map (maximum . map T.length) (transpose rows)
    line cells = T.stripEnd $ T.intercalate "  " (zipWith (`T.justifyLeft` ' ') widths cells)

-- | One row of `tc ps` output
psRow :: InstanceView -> [T.Text]
psRow i = [unInstanceId (iviewId i), specImage (iviewSpec i), node, ip, status]
  where
    (node, ip) = case iviewPlacement i of
      Unplaced -> ("-", "-")
      Placed n a -> (unNodeId n, renderIPv4 a)
    status
      | iviewPlacement i == Unplaced = "pending"
      | iviewRunning i = "running"
      | otherwise = "not running"

-- | How a node's status shows in the ALIVE column
statusText :: NodeStatus -> T.Text
statusText Alive = "yes"
statusText Dead = "no"
statusText Unknown = "unknown"

-- | One row of `tc nodes` output
nodeRow :: NodeView -> [T.Text]
nodeRow n =
  [ unNodeId (nviewName n),
    nviewAddr n,
    nviewSubnet n,
    T.pack (show $ nviewCpus n),
    T.pack (show $ nviewMemMb n),
    statusText (nviewStatus n),
    T.pack (show $ nviewInstances n)
  ]

main :: IO ()
main = do
  (url, c) <- execParser $ info ((,) <$> serverOpt <*> cmd <**> helper) (progDesc "TypeCloud CLI :)")
  mgr <- newManager defaultManagerSettings
  base <- parseBaseUrl url

  let env = mkClientEnv mgr base
      go :: ClientM a -> (a -> IO ()) -> IO ()
      go act k = runClientM act env >>= either die' k
  case c of
    Nodes -> go listNodesC $ \ns -> do
      mapM_ T.putStrLn $
        table $
          ["NAME", "ADDR", "SUBNET", "CPUS", "MEM", "ALIVE", "INST"] : map nodeRow ns
    Ps -> go listInstancesC $ \is ->
      mapM_ T.putStrLn $ table $ ["ID", "IMAGE", "NODE", "IP", "STATUS"] : map psRow is
    Run s -> go (createInstanceC s) $ \i -> T.putStrLn (unInstanceId (iviewId i))
    Rm i -> go (deleteInstanceC i) $ \_ -> pure ()
    VolCreate gb n -> go (createVolumeC (NewVolume gb n)) $ \v ->
      T.putStrLn (unVolumeId (vId v) <> " on " <> unNodeId (vNode v))
    VolLs -> go listVolumesC $ \vs ->
      mapM_ T.putStrLn $
        table $
          ["ID", "SIZE", "NODE"] : [[unVolumeId (vId v), T.pack (show (vSizeGb v)) <> " GB", unNodeId (vNode v)] | v <- vs]
    VolRm v -> go (deleteVolumeC v) $ \_ -> pure ()
  where
    serverOpt = strOption (long "server" <> short 's' <> value "http://localhost:8080" <> showDefault <> help "control plane URL")
    die' e = do
      hPutStrLn
        stderr
        ( case e of
            FailureResponse _ r -> "Error: " <> BL.unpack (responseBody r)
            _ -> "Error: " <> describeClientError e
        )
      exitFailure
