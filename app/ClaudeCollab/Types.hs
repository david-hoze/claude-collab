module ClaudeCollab.Types where

import Data.Aeson
import Data.Aeson.Types (prependFailure, typeMismatch)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)

-- | Message types for the channel
data MessageType = Chat | Status | Claim | Unclaim | Staged | Commit | Reserve | Release
  deriving (Show, Eq, Generic)

instance ToJSON MessageType where
  toJSON Chat    = String "chat"
  toJSON Status  = String "status"
  toJSON Claim   = String "claim"
  toJSON Unclaim = String "unclaim"
  toJSON Staged  = String "staged"
  toJSON Commit  = String "commit"
  toJSON Reserve = String "reserve"
  toJSON Release = String "release"

instance FromJSON MessageType where
  parseJSON (String "chat")    = pure Chat
  parseJSON (String "status")  = pure Status
  parseJSON (String "claim")   = pure Claim
  parseJSON (String "unclaim") = pure Unclaim
  parseJSON (String "staged")  = pure Staged
  parseJSON (String "commit")  = pure Commit
  parseJSON (String "reserve") = pure Reserve
  parseJSON (String "release") = pure Release
  parseJSON invalid = prependFailure "parsing MessageType failed, "
                        (typeMismatch "String" invalid)

-- | A channel message
data Message = Message
  { msgSeq    :: Int
  , msgTs     :: UTCTime
  , msgFrom   :: Text
  , msgType   :: MessageType
  , msgMsg    :: Text
  , msgTarget :: Maybe Text
  } deriving (Show, Eq, Generic)

instance ToJSON Message where
  toJSON Message{..} = object $
    [ "seq"  .= msgSeq
    , "ts"   .= msgTs
    , "from" .= msgFrom
    , "type" .= msgType
    , "msg"  .= msgMsg
    ] ++ maybe [] (\t -> ["target" .= t]) msgTarget

instance FromJSON Message where
  parseJSON = withObject "Message" $ \v -> Message
    <$> v .: "seq"
    <*> v .: "ts"
    <*> v .: "from"
    <*> v .: "type"
    <*> v .: "msg"
    <*> v .:? "target"

-- | Per-file claim state
data ClaimState = ClaimState
  { claimStaged    :: Bool
  , claimCommitMsg :: Maybe Text
  } deriving (Show, Eq, Generic)

instance ToJSON ClaimState where
  toJSON ClaimState{..} = object
    [ "staged"     .= claimStaged
    , "commit_msg" .= claimCommitMsg
    ]

instance FromJSON ClaimState where
  parseJSON = withObject "ClaimState" $ \v -> ClaimState
    <$> v .: "staged"
    <*> v .: "commit_msg"

-- | Per-agent info in the registry
data AgentInfo = AgentInfo
  { agentStarted :: UTCTime
  , agentStatus  :: Text
  , agentClaimed :: Map FilePath ClaimState
  , agentName    :: Maybe Text
  } deriving (Show, Eq, Generic)

instance ToJSON AgentInfo where
  toJSON AgentInfo{..} = object $
    [ "started" .= agentStarted
    , "status"  .= agentStatus
    , "claimed" .= agentClaimed
    ] ++ maybe [] (\n -> ["name" .= n]) agentName

instance FromJSON AgentInfo where
  parseJSON = withObject "AgentInfo" $ \v -> AgentInfo
    <$> v .: "started"
    <*> v .: "status"
    <*> v .: "claimed"
    <*> v .:? "name"

-- | The full registry
type Registry = Map Text AgentInfo

-- | Resource definition
data ResourceDef = ResourceDef
  { resDefaultTtl  :: Int
  , resDescription :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON ResourceDef where
  toJSON ResourceDef{..} = object
    [ "default_ttl"  .= resDefaultTtl
    , "description"  .= resDescription
    ]

instance FromJSON ResourceDef where
  parseJSON = withObject "ResourceDef" $ \v -> ResourceDef
    <$> v .: "default_ttl"
    <*> v .: "description"

type Resources = Map Text ResourceDef

-- | Active reservation
data Reservation = Reservation
  { resHolder   :: Text
  , resAcquired :: UTCTime
  , resTtl      :: Int
  , resPurpose  :: Maybe Text
  } deriving (Show, Eq, Generic)

instance ToJSON Reservation where
  toJSON Reservation{..} = object
    [ "holder"   .= resHolder
    , "acquired" .= resAcquired
    , "ttl"      .= resTtl
    , "purpose"  .= resPurpose
    ]

instance FromJSON Reservation where
  parseJSON = withObject "Reservation" $ \v -> Reservation
    <$> v .: "holder"
    <*> v .: "acquired"
    <*> v .: "ttl"
    <*> v .: "purpose"

type Reservations = Map Text Reservation

-- | Exit codes
exitSuccess, exitGeneral, exitLockTimeout, exitGitFailed :: Int
exitSuccess     = 0
exitGeneral     = 1
exitLockTimeout = 2
exitGitFailed   = 3

-- | Base directory for all agent data
agentsBaseDir :: FilePath
agentsBaseDir = ".claude/agents"

channelDir :: FilePath
channelDir = agentsBaseDir ++ "/channel"

registryPath :: FilePath
registryPath = agentsBaseDir ++ "/registry.json"

resourcesPath :: FilePath
resourcesPath = agentsBaseDir ++ "/resources.json"

reservationsPath :: FilePath
reservationsPath = agentsBaseDir ++ "/reservations.json"

channelLockDir :: FilePath
channelLockDir = channelDir ++ "/.lock"

gitLockDir :: FilePath
gitLockDir = agentsBaseDir ++ "/.git-lock"

reserveLockDir :: FilePath
reserveLockDir = agentsBaseDir ++ "/.reserve-lock"

seqFile :: FilePath
seqFile = channelDir ++ "/.seq"

agentDir :: Text -> FilePath
agentDir hash = agentsBaseDir ++ "/" ++ T.unpack hash

cursorFile :: Text -> FilePath
cursorFile hash = agentDir hash ++ "/cursor"

outputLog :: Text -> FilePath
outputLog hash = agentDir hash ++ "/output.log"

-- | Default resources created by init
defaultResources :: Resources
defaultResources = Map.fromList
  [ ("test",    ResourceDef 300 "Test suite")
  , ("build",   ResourceDef 300 "Build / compile")
  , ("install", ResourceDef 300 "Package installation (npm, pip, etc.)")
  ]
