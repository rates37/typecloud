{-# LANGUAGE OverloadedStrings #-}

-- Pure addressing logic. The overlay is in 10.100.0.0/16
-- node N owns the subnet 10.100.N.0/24 (for N \in 1..254)
-- Inside a node's /24:
--   - .1 is the gateway
--   - .2-.254 are available to hand to containers
--   - .0 (network) and .255 (broadcast) are reserved (never handed out)
module TC.Net
  ( IPv4 (..),
    renderIPv4,
    parseIPv4,
    SubnetId (..),
    subnetCidr,
    gatewayIp,
    hostIp,
    parseCidr24,
    allocSubnet,
    allocIp,
  )
where

import Control.Monad
import Data.Aeson
import Data.Bits
import Data.Char (isDigit)
import Data.List (find)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)

-- | An IPv4 address, stored as its 32-bit big-endian value
-- Shown and serialised to JSON as a dotted-quad string
newtype IPv4 = IPv4 Word32 deriving (Eq, Ord)

instance Show IPv4 where show = T.unpack . renderIPv4

-- | Dotted-quad IP address rendering, e.g. "10.100.3.1"
renderIPv4 :: IPv4 -> Text
renderIPv4 (IPv4 w) = T.intercalate "." [T.pack (show ((w `shiftR` s) .&. 0xFF)) | s <- [24, 16, 8, 0]]

instance ToJSON IPv4 where toJSON = String . renderIPv4

instance FromJSON IPv4 where parseJSON = withText "IPv4" $ maybe (fail "invalid IPv4") pure . parseIPv4

-- | Inverse of renderIPv4. Requires four decimal octets of 1-3 digits
parseIPv4 :: Text -> Maybe IPv4
parseIPv4 t = case T.splitOn "." t of
  [a, b, c, d] -> do
    [a', b', c', d'] <- mapM octet [a, b, c, d]
    pure . IPv4 $ a' `shiftL` 24 .|. b' `shiftL` 16 .|. c' `shiftL` 8 .|. d'
  _ -> Nothing
  where
    octet x = do
      guard (not (T.null x) && T.all isDigit x && T.length x <= 3)
      let n = read (T.unpack x) :: Int
      guard (n <= 255)
      pure (fromIntegral n :: Word32)

-- | Identifies a node's subnet: SubnetId n is 10.100.n.0/24.
-- Valid values are 1..254. Prefer 'allocSubnet' to obtain new subnets
newtype SubnetId = SubnetId Int deriving (Eq, Ord, Show)

instance ToJSON SubnetId where toJSON (SubnetId n) = toJSON n

instance FromJSON SubnetId where
  parseJSON v = do
    n <- parseJSON v
    if n >= 1 && n <= 254 then pure (SubnetId n) else fail "subnet out of range"

-- | 10.100.0.0, the start of the overlay
overlayBase :: Word32
overlayBase = 10 `shiftL` 24 .|. 100 `shiftL` 16

-- | hostIp s h is address .h within subnet s
hostIp :: SubnetId -> Int -> IPv4
hostIp (SubnetId n) h = IPv4 $ overlayBase .|. fromIntegral n `shiftL` 8 .|. fromIntegral h

-- | The node's bridge address (.1) in its subnet.
gatewayIp :: SubnetId -> IPv4
gatewayIp s = hostIp s 1

-- | CIDR notation for a subnet. E.g. SubnetId 3 becomes "10.100.3.0/24".
subnetCidr :: SubnetId -> Text
subnetCidr s = renderIPv4 (hostIp s 0) <> "/24"

-- | Inverse of subnetCidr (e.g., "10.100.3.0/24" -> SubnetId 3)
parseCidr24 :: Text -> Maybe SubnetId
parseCidr24 t = case T.breakOn "/" t of
  (ip, "/24") -> do
    IPv4 w <- parseIPv4 ip
    let n = fromIntegral $ (w `shiftR` 8) .&. 0xFF
    -- mask keeps the /16 prefix and the host byte so both must match
    guard $ w .&. 0xFFFF00FF == overlayBase && n >= 1 && n <= 254
    pure (SubnetId n)
  _ -> Nothing

-- | Picks the smallest subnet not in the given list, or 'Nothing' if all 254
-- are taken. Pass /every/ subnet currently in use to keep all subnets unique
allocSubnet :: [SubnetId] -> Maybe SubnetId
allocSubnet used = find (`notElem` used) (map SubnetId [1 .. 254])

-- | Picks the smallest unused container address (.2-.254) in a node's
-- subnet, or 'Nothing' if it is full. Addresses in the set that lie outside
-- the subnet are ignored
allocIp :: SubnetId -> Set IPv4 -> Maybe IPv4
allocIp s used = find (`Set.notMember` used) [hostIp s h | h <- [2 .. 254]]
