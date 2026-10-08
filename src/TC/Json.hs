module TC.Json (jsonOpts) where

import Data.Aeson (Options (..), defaultOptions)
import Data.Char (isLower, toLower)

-- | JSON options that removes leading lower case chars, converts field names to 
-- lowerCamelCase and omit fields that are Nothing e.g., "vmMemMb" -> "memMb",
-- and "nvolSizeGb" -> "sizeGb"
jsonOpts :: Options
jsonOpts =
  defaultOptions
    { fieldLabelModifier = lower1 . dropWhile isLower,
      omitNothingFields = True
    }
  where
    lower1 (c : cs) = toLower c : cs
    lower1 [] = []
