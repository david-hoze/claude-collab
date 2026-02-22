module ClaudeCollab.Registry
  ( readRegistry
  , writeRegistry
  , modifyRegistry
  , resolveAgent
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import System.Directory (renameFile)
import System.FilePath ((<.>))

import ClaudeCollab.Types

-- | Read the registry, returning empty map if file doesn't exist or is invalid.
readRegistry :: IO Registry
readRegistry = do
  result <- try (BS.readFile registryPath) :: IO (Either SomeException BS.ByteString)
  case result of
    Left _  -> return Map.empty
    Right bs ->
      case eitherDecodeStrict' bs of
        Left _  -> return Map.empty
        Right r -> return r

-- | Write the registry atomically via temp file + rename.
writeRegistry :: Registry -> IO ()
writeRegistry reg = do
  let tmpPath = registryPath <.> "tmp"
  BL.writeFile tmpPath (encode reg)
  renameFile tmpPath registryPath

-- | Read-modify-write the registry.
modifyRegistry :: (Registry -> IO (Registry, a)) -> IO a
modifyRegistry f = do
  reg <- readRegistry
  (reg', result) <- f reg
  writeRegistry reg'
  return result

-- | Resolve a name-or-hash to a hash. If the input matches a registered
-- hash directly, return it. Otherwise search agent names for a match.
-- Returns the input unchanged if no match is found (commands will fail
-- with "agent not found" naturally).
resolveAgent :: Text -> IO Text
resolveAgent nameOrHash = do
  reg <- readRegistry
  if Map.member nameOrHash reg
    then return nameOrHash
    else case [ h | (h, info) <- Map.toList reg
                  , agentName info == Just nameOrHash ] of
           (h:_) -> return h
           []    -> return nameOrHash
