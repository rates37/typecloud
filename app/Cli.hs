{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_)
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
import Text.Printf (printf)

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
      printf "%-12s %-16s %-16s %-5s %-7s %-6s %s\n" ("NAME" :: String) ("ADDR" :: String) ("SUBNET" :: String) ("CPUS" :: String) ("MEM" :: String) ("ALIVE" :: String) ("INST" :: String)
      forM_ ns $ \n -> printf "%-12s %-16s %-16s %-5d %-7d %-6s %d\n" (T.unpack (unNodeId (nviewName n))) (T.unpack (nviewAddr n)) (T.unpack (nviewSubnet n)) (nviewCpus n) (nviewMemMb n) (if nviewAlive n then "yes" :: String else "no" :: String) (nviewInstances n)
    Ps -> go listInstancesC $ \is ->
      mapM_ T.putStrLn $ table $ ["ID", "IMAGE", "NODE", "IP", "STATUS"] : map psRow is
    Run s -> go (createInstanceC s) $ \i -> T.putStrLn (unInstanceId (iviewId i))
    Rm i -> go (deleteInstanceC i) $ \_ -> pure ()
    VolCreate gb n -> go (createVolumeC (NewVolume gb n)) $ \v ->
      T.putStrLn (unVolumeId (vId v) <> " on " <> unNodeId (vNode v))
    VolLs -> go listVolumesC $ \vs -> forM_ vs $ \v ->
      printf "%-8s %3d GB  %s\n" (T.unpack (unVolumeId (vId v))) (vSizeGb v) (T.unpack (unNodeId (vNode v)))
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
