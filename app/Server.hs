module Main (main) where

import Control.Concurrent (forkIO)
import Network.Wai.Handler.Warp (run)
import Options.Applicative
import TC.Server

data Opts = Opts
  { port :: Int,
    state :: Maybe FilePath
  }

opts :: Parser Opts
opts = Opts <$> option auto (long "port" <> value 8080 <> showDefault <> help "listen port")
            <*> optional (strOption (long "state" <> metavar "FILE" <> help "path to JSON snapshot file (omit if in-memory only required)"))

main :: IO ()
main = do
    o <- execParser $ info (opts <**> helper) (progDesc "typecloud control plane")
    env <- newEnv (state o)
    _ <- forkIO $ reaperLoop env
    putStrLn $ "tc-server listening on port " <> show (port o)
    run (port o) (application env)
