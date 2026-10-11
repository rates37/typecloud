module Main (main) where

import Network.Wai.Handler.Warp (run)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import TC.ObjStore

main :: IO ()
main = do
  (p, root) <- execParser (info (((,) <$> port <*> dir) <**> helper) (progDesc "typecloud object store"))
  createDirectoryIfMissing True root
  putStrLn ("tc-objstore running on: " <> show p <> ", data in " <> root)
  run p (objStoreApp root)
  where
    port = option auto (long "port" <> value 9000 <> showDefault)
    dir = strOption (long "dir" <> value "./objects" <> showDefault)
