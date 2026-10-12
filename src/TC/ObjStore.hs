{-# LANGUAGE OverloadedStrings #-}

-- | A S3-like object store, just backed by a directory
--
-- PUT /buckets/<bucket>/<key..> upload
-- GET /buckets/<bucket>/<key..> download
-- DELETE /buckets/<bucket>/<key..> delete
-- GET /buckets/<bucket> list keys in bucket
module TC.ObjStore where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Either (isRight)
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types
import Network.Wai
import System.Directory
import System.FilePath (takeDirectory, (</>))

-- | Turn URL segemnts into a path under `root`, or refuse if invalid,
-- e.g., for security reasons to prevent directory traversal attack
safePath :: FilePath -> [Text] -> Maybe FilePath
safePath root segs
  | null segs = Nothing
  | all ok segs = Just (foldl (</>) root (map T.unpack segs))
  | otherwise = Nothing
  where
    ok s =
      not (T.null s)
        && s /= "."
        && s /= ".."
        && T.all (\c -> c /= '/' && c /= '\\' && c /= '\0') s
        -- don't allow writing tmp files since it's used for in-progress uploads:
        && not (".tmp" `T.isSuffixOf` s)

-- | Largest object accepted in one PUT, in bytes (1GiB):
maxObjectBytes :: Integer
maxObjectBytes = 1024 * 1024 * 1024

objStoreApp :: FilePath -> Application
objStoreApp root req respond = case (requestMethod req, pathInfo req) of
  ("GET", ["buckets", b]) -> withPath [b] list
  ("PUT", "buckets" : b : key@(_ : _))
    | tooBig -> respond $ plain status413 "object too large\n"
    | otherwise -> withPath (b : key) put
  ("GET", "buckets" : b : key@(_ : _)) -> withPath (b : key) get
  ("HEAD", "buckets" : b : key@(_ : _)) -> withPath (b : key) get
  ("DELETE", "buckets" : b : key@(_ : _)) -> withPath (b : key) (del (root </> T.unpack b))
  _ -> respond $ plain status404 "not found\n"
  where
    withPath segs k = maybe (respond $ plain status400 "bad path\n") k (safePath root segs)

    tooBig = case lookup "Content-Length" (requestHeaders req) of
      Just v | Just (n, _) <- B.readInteger v -> n > maxObjectBytes
      _ -> False

    -- stream the body to a temp file, then rename
    -- reader never sees a partially written file and memory usage is minimised
    put path = do
      createDirectoryIfMissing True (takeDirectory path)
      let tmp = path <> ".tmp"
      BS.writeFile tmp BS.empty
      let loop = do
            chunk <- getRequestBodyChunk req
            unless (BS.null chunk) (BS.appendFile tmp chunk >> loop)
      loop
      renameFile tmp path
      respond $ plain status201 ""

    get path = do
      ok <- doesFileExist path
      respond $
        if ok
          then responseFile status200 [] path Nothing
          else plain status404 "no such key\n"

    del bucketDir path = do
      ok <- doesFileExist path
      if ok
        then removeFile path >> prune bucketDir (takeDirectory path) >> respond (plain status204 "")
        else respond $ plain status404 "no such key\n"

    -- remove directories that the delete left empty, stopping at the bucket itself
    prune bucketDir dir = when (dir /= bucketDir) $ do
      empty <- null <$> listDirectory dir
      when empty $ do
        removed <- try (removeDirectory dir) :: IO (Either IOException ())
        when (isRight removed) $ prune bucketDir (takeDirectory dir)

    list dir = do
      ok <- doesDirectoryExist dir
      if not ok
        then respond (plain status404 "no such bucket\n")
        else do
          keys <- walk dir ""
          respond $ plain status200 (B.unlines (map B.pack keys))

    walk dir prefix = do
      entries <- listDirectory dir
      concat
        <$> mapM
          ( \e -> do
              let full = dir </> e
                  rel = if null prefix then e else prefix </> e
              isDir <- doesDirectoryExist full
              if isDir then walk full rel else pure [rel | not (".tmp" `isSuffixOf` e)]
          )
          entries

plain :: Status -> B.ByteString -> Response
plain st body = responseLBS st [("Content-Type", "text/plain")] (BL.fromStrict body)
