module ClaudeCollab.Commands
  ( cmdInit
  , cmdSend
  , cmdRead
  , cmdWatch
  , cmdFilesClaim
  , cmdFilesUnclaim
  , cmdFilesStatus
  , cmdCommit
  , cmdReserve
  , cmdRelease
  , cmdReservations
  , cmdList
  , cmdCleanup
  , cmdTee
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive,
                         removeFile, renameFile)
import System.Exit (ExitCode(..), exitWith)
import System.Process (readProcessWithExitCode)
import System.FilePath ((<.>))
import System.IO (hFlush, hPutStrLn, stderr, stdin, stdout)
import qualified Data.ByteString.Char8 as BS8

import ClaudeCollab.Channel
import ClaudeCollab.Git
import ClaudeCollab.Lock
import ClaudeCollab.Registry
import ClaudeCollab.Types

-- Helpers

printJSON :: BL8.ByteString -> IO ()
printJSON bs = BL8.putStrLn bs >> hFlush stdout

exitWithCode :: Int -> IO a
exitWithCode n = exitWith (if n == 0 then ExitSuccess else ExitFailure n)

printError :: String -> IO ()
printError = hPutStrLn stderr

jsonError :: Text -> IO ()
jsonError msg = printJSON $ encode $ object ["ok" .= False, "error" .= msg]

-- | Generate a random 8-character hex hash
generateHash :: IO Text
generateHash = do
  (code, out, _) <- readProcessWithExitCode "openssl" ["rand", "-hex", "4"] ""
  case code of
    ExitSuccess -> pure $ T.strip (T.pack out)
    _           -> do
      -- Fallback: use current time in picoseconds as entropy
      now <- getCurrentTime
      let s = show now  -- e.g. "2026-02-21 21:20:05.123456 UTC"
          digits = filter (\c -> c >= '0' && c <= '9') s
          hexChars = "0123456789abcdef"
          toHex n = [hexChars !! (n `mod` 16)]
          h = concatMap (\c -> toHex (fromEnum c)) (take 8 digits)
      pure (T.pack (take 8 (h ++ "00000000")))

-- | Initialize an agent
cmdInit :: Maybe Text -> IO ()
cmdInit mbHash = do
  hash <- case mbHash of
    Just h  -> pure h
    Nothing -> generateHash
  -- Create directories
  createDirectoryIfMissing True channelDir
  createDirectoryIfMissing True (agentDir hash)

  -- Create resources.json with defaults if it doesn't exist
  resExists <- doesFileExist resourcesPath
  if not resExists
    then BL.writeFile resourcesPath (encode defaultResources)
    else return ()

  -- Create reservations.json as {} if it doesn't exist
  revExists <- doesFileExist reservationsPath
  if not revExists
    then BL.writeFile reservationsPath (encode (Map.empty :: Reservations))
    else return ()

  -- Initialize cursor to current seq
  cur <- readSeq
  writeCursor hash cur

  -- Add to registry
  now <- getCurrentTime
  let info = AgentInfo
        { agentStarted = now
        , agentStatus  = "active"
        , agentClaimed = Map.empty
        }
  modifyRegistry $ \reg -> return (Map.insert hash info reg, ())

  -- Send join message
  _ <- sendMessage hash Status ("Agent " <> hash <> " joined") Nothing

  -- Print result
  printJSON $ encode $ object
    [ "ok"        .= True
    , "hash"      .= hash
    , "agent_dir" .= agentDir hash
    ]

-- | Send a message
cmdSend :: Text -> Text -> MessageType -> Maybe Text -> IO ()
cmdSend hash msg msgtype target = do
  n <- sendMessage hash msgtype msg target
  printJSON $ encode $ object
    [ "ok"  .= True
    , "seq" .= n
    ]

-- | Read messages
cmdRead :: Text -> Bool -> Int -> Maybe Int -> IO ()
cmdRead hash wait timeout mbFrom = do
  (msgs, cur) <- case mbFrom of
    Just fromSeq -> readMessagesFrom fromSeq
    Nothing
      | wait      -> readMessagesWait hash timeout
      | otherwise -> readMessages hash
  printJSON $ encode $ object
    [ "messages" .= msgs
    , "cursor"   .= cur
    ]

-- | Watch for messages (long-running)
cmdWatch :: Text -> IO ()
cmdWatch hash = do
  watchMessages hash $ \msg -> do
    BL8.putStrLn (encode msg)
    hFlush stdout

-- | Claim files
cmdFilesClaim :: Text -> [FilePath] -> Bool -> IO ()
cmdFilesClaim hash paths shared = do
  reg <- readRegistry
  now <- getCurrentTime

  -- Ensure agent exists in registry
  let myInfo = Map.findWithDefault
        (AgentInfo now "active" Map.empty)
        hash reg

  let otherAgents = Map.delete hash reg

  -- Process each path
  let go [] claimed sharedFiles rejected regAcc myClaimsAcc =
        return (claimed, sharedFiles, rejected, regAcc, myClaimsAcc)
      go (p:ps) claimed sharedFiles rejected regAcc myClaimsAcc = do
        let normalP = normalizeSlashes p
        -- Check if already claimed by this agent
        if Map.member normalP myClaimsAcc
          then go ps claimed sharedFiles rejected regAcc myClaimsAcc
          else do
            -- Check if claimed by another agent
            let claimers = findClaimers normalP otherAgents
            case claimers of
              [] -> do
                -- Unclaimed, claim it
                let newClaim = ClaimState False Nothing
                go ps (normalP : claimed) sharedFiles rejected regAcc
                   (Map.insert normalP newClaim myClaimsAcc)
              ((otherHash, _):_)
                | not shared -> do
                    printError $ "WARNING: " ++ normalP ++ " is claimed by " ++ T.unpack otherHash
                      ++ ". Coordinate in channel, then use --shared to co-claim."
                    go ps claimed sharedFiles (normalP : rejected) regAcc myClaimsAcc
                | otherwise -> do
                    -- Co-claim
                    let newClaim = ClaimState False Nothing
                    printError $ "INFO: " ++ normalP ++ " is now co-claimed with " ++ T.unpack otherHash
                      ++ ". Coordinate changes in channel."
                    go ps claimed (normalP : sharedFiles) rejected regAcc
                       (Map.insert normalP newClaim myClaimsAcc)
      -- end go

  (claimed, sharedFiles, rejected, _, myClaimsNew) <-
    go paths [] [] [] reg (agentClaimed myInfo)

  -- Update registry
  let updatedInfo = myInfo { agentClaimed = myClaimsNew }
  let updatedReg = Map.insert hash updatedInfo reg
  writeRegistry updatedReg

  -- Send channel messages for newly claimed files
  mapM_ (\p -> sendMessage hash Claim ("Claiming " <> T.pack p) (Just $ T.pack p)) claimed

  -- Send channel messages for co-claimed files
  mapM_ (\p -> do
    let claimers = findClaimers p (Map.delete hash reg)
    let otherHashes = T.intercalate ", " (map fst claimers)
    sendMessage hash Claim
      ("Co-claiming " <> T.pack p <> " (shared with " <> otherHashes <> ")")
      (Just $ T.pack p)
    ) sharedFiles

  -- Print result
  let ok = null rejected
  printJSON $ encode $ object
    [ "ok"       .= ok
    , "claimed"  .= map T.pack claimed
    , "shared"   .= map T.pack sharedFiles
    , "rejected" .= map T.pack rejected
    ]

  if not ok then exitWithCode exitGeneral else return ()

-- | Find which agents have claimed a file
findClaimers :: FilePath -> Map Text AgentInfo -> [(Text, ClaimState)]
findClaimers path agents =
  [ (h, cs)
  | (h, info) <- Map.toList agents
  , (fp, cs) <- Map.toList (agentClaimed info)
  , normalizeSlashes fp == normalizeSlashes path
  ]

-- | Normalize path separators to forward slashes
normalizeSlashes :: FilePath -> FilePath
normalizeSlashes = map (\c -> if c == '\\' then '/' else c)

-- | Unclaim files
cmdFilesUnclaim :: Text -> [FilePath] -> IO ()
cmdFilesUnclaim hash paths = do
  modifyRegistry $ \reg -> do
    case Map.lookup hash reg of
      Nothing -> return (reg, ())
      Just info -> do
        let newClaimed = foldr (\p m -> Map.delete (normalizeSlashes p) m) (agentClaimed info) paths
        let newInfo = info { agentClaimed = newClaimed }
        return (Map.insert hash newInfo reg, ())

  -- Send unclaim messages
  mapM_ (\p -> sendMessage hash Unclaim ("Unclaimed " <> T.pack p) (Just $ T.pack p)) paths

  printJSON $ encode $ object
    [ "ok"        .= True
    , "unclaimed" .= map T.pack paths
    ]

-- | Show file status
cmdFilesStatus :: IO ()
cmdFilesStatus = do
  reg <- readRegistry
  gitResult <- gitStatus
  case gitResult of
    Left err -> do
      jsonError err
      exitWithCode exitGitFailed
    Right files -> do
      let entries = map (buildStatusEntry reg) files
      printJSON $ encode $ object
        [ "ok"    .= True
        , "files" .= entries
        ]

buildStatusEntry :: Registry -> GitFileStatus -> Value
buildStatusEntry reg gfs =
  let path = normalizeSlashes (gfsPath gfs)
      owner = findOwner path reg
  in object
    [ "path"   .= path
    , "status" .= gfsStatus gfs
    , "owner"  .= owner
    ]

findOwner :: FilePath -> Registry -> Text
findOwner path reg =
  case [ h | (h, info) <- Map.toList reg
           , Map.member path (agentClaimed info)
       ] of
    (h:_) -> h
    []    -> "unclaimed"

-- | Commit an agent's claimed files
cmdCommit :: Text -> Text -> IO ()
cmdCommit hash commitMsg = do
  reg <- readRegistry
  case Map.lookup hash reg of
    Nothing -> do
      jsonError ("Agent " <> hash <> " not found in registry")
      exitWithCode exitGeneral
    Just myInfo -> do
      -- Step 1: Check for pending commit
      let hasPending = any claimStaged (Map.elems (agentClaimed myInfo))
      if hasPending
        then do
          let pendingFiles = [ fp | (fp, cs) <- Map.toList (agentClaimed myInfo), claimStaged cs ]
          let waitingOn = findWaitingOn pendingFiles hash reg
          printError $ "WARNING: You have a pending commit (waiting on "
            ++ T.unpack (T.intercalate ", " (map fst waitingOn))
            ++ " for " ++ show (map snd waitingOn) ++ "). Cannot commit again until it resolves."
          exitWithCode exitGeneral
        else doCommit hash commitMsg myInfo reg

doCommit :: Text -> Text -> AgentInfo -> Registry -> IO ()
doCommit hash commitMsg myInfo reg = do
  -- Step 2: Get dirty files
  gitResult <- gitStatus
  case gitResult of
    Left err -> do
      jsonError err
      exitWithCode exitGitFailed
    Right gitFiles -> do
      let dirtyPaths = map (normalizeSlashes . gfsPath) gitFiles
      let myClaimed = Map.keys (agentClaimed myInfo)
      let myDirtyFiles = filter (`elem` dirtyPaths) myClaimed

      -- Step 3: Warn about unclaimed dirty files
      let unclaimedDirty = filter (\p -> findOwner p reg == "unclaimed") dirtyPaths
      mapM_ (\p -> printError $ "WARNING: Unclaimed dirty file: " ++ p) unclaimedDirty

      if null myDirtyFiles
        then do
          printJSON $ encode $ object
            [ "ok"       .= True
            , "message"  .= ("No dirty claimed files to commit" :: Text)
            ]
        else do
          -- Step 4: Check co-claimed files
          let otherAgents = Map.delete hash reg
          let coClaimedInfo = findCoClaimedFiles myDirtyFiles hash otherAgents
          let needsWaiting = any (not . allCoClaimersStaged) coClaimedInfo

          if needsWaiting
            then doStage hash commitMsg myDirtyFiles coClaimedInfo reg myInfo
            else doFullCommit hash commitMsg myDirtyFiles coClaimedInfo reg myInfo

-- | Stage files and wait for co-claimers
doStage :: Text -> Text -> [FilePath] -> [(FilePath, [(Text, ClaimState)])]
        -> Registry -> AgentInfo -> IO ()
doStage hash commitMsg dirtyFiles coClaimedInfo reg myInfo = do
  -- git add all dirty claimed files
  addResult <- gitAdd dirtyFiles
  case addResult of
    Left err -> do
      jsonError err
      exitWithCode exitGitFailed
    Right () -> do
      -- Mark all as staged in registry
      let newClaimed = Map.mapWithKey
            (\fp cs -> if fp `elem` dirtyFiles
              then cs { claimStaged = True, claimCommitMsg = Just commitMsg }
              else cs)
            (agentClaimed myInfo)
      let newInfo = myInfo { agentClaimed = newClaimed }
      let newReg = Map.insert hash newInfo reg
      writeRegistry newReg

      -- Build waiting_on info
      let waitingOn = Map.fromList
            [ (T.pack fp, map fst others)
            | (fp, others) <- coClaimedInfo
            , not (allCoClaimersStaged (fp, others))
            ]

      -- Send channel message
      let waitHashes = T.intercalate ", " $ concatMap snd $ Map.toList waitingOn
      _ <- sendMessage hash Staged
        ("Staged " <> T.pack (show (length dirtyFiles)) <> " files, waiting on " <> waitHashes)
        Nothing

      printJSON $ encode $ object
        [ "ok"         .= True
        , "staged"     .= map T.pack dirtyFiles
        , "waiting_on" .= waitingOn
        ]

-- | Perform the actual git commit
doFullCommit :: Text -> Text -> [FilePath] -> [(FilePath, [(Text, ClaimState)])]
             -> Registry -> AgentInfo -> IO ()
doFullCommit hash commitMsg dirtyFiles coClaimedInfo reg myInfo = do
  -- Acquire git lock
  withMkdirLock gitLockDir 30.0 $ do
    -- Re-stage everything fresh
    addResult <- gitAdd dirtyFiles
    case addResult of
      Left err -> do
        jsonError err
        exitWithCode exitGitFailed
      Right () -> do
        -- Build combined commit message
        let combinedMsg = buildCombinedMsg hash commitMsg coClaimedInfo reg
        commitResult <- gitCommit combinedMsg
        case commitResult of
          Left err -> do
            jsonError ("git commit failed: " <> err)
            exitWithCode exitGitFailed
          Right shortHash -> do
            -- Post-commit cleanup
            let newReg = postCommitCleanup hash dirtyFiles coClaimedInfo reg myInfo
            writeRegistry newReg

            -- Send channel message
            _ <- sendMessage hash Commit
              ("Committed: " <> shortHash)
              (Just $ T.intercalate ", " $ map T.pack dirtyFiles)

            printJSON $ encode $ object
              [ "ok"        .= True
              , "commit"    .= shortHash
              , "committed" .= map T.pack dirtyFiles
              ]

-- | Build the combined commit message for co-claimed files
buildCombinedMsg :: Text -> Text -> [(FilePath, [(Text, ClaimState)])] -> Registry -> String
buildCombinedMsg hash commitMsg coClaimedInfo _reg =
  let -- Collect messages from co-claimers who have staged
      otherMsgs = concatMap (\(_, others) ->
        [ "[" ++ T.unpack h ++ "] " ++ maybe "" T.unpack (claimCommitMsg cs)
        | (h, cs) <- others
        , claimStaged cs
        , h /= hash
        ]) coClaimedInfo
      myMsg = "[" ++ T.unpack hash ++ "] " ++ T.unpack commitMsg
      allMsgs = nubStrings (otherMsgs ++ [myMsg])
  in if null otherMsgs
     then T.unpack commitMsg  -- Solo commit, use plain message
     else unlines allMsgs
  where
    nubStrings [] = []
    nubStrings (x:xs) = x : nubStrings (filter (/= x) xs)

-- | Clean up registry after a successful commit
postCommitCleanup :: Text -> [FilePath] -> [(FilePath, [(Text, ClaimState)])]
                  -> Registry -> AgentInfo -> Registry
postCommitCleanup hash dirtyFiles coClaimedInfo reg myInfo =
  let -- Remove committed files from this agent's claims
      myNewClaimed = foldr Map.delete (agentClaimed myInfo) dirtyFiles
      myNewInfo = myInfo { agentClaimed = myNewClaimed }
      reg1 = Map.insert hash myNewInfo reg

      -- For co-claimed files, unclaim for ALL co-claimers
      reg2 = foldr (\(fp, others) r ->
        foldr (\(otherHash, _) r' ->
          Map.adjust (\ai -> ai { agentClaimed = Map.delete fp (agentClaimed ai) })
            otherHash r'
          ) r others
        ) reg1 coClaimedInfo
  in reg2

-- | Find co-claimed files and their co-claimers
findCoClaimedFiles :: [FilePath] -> Text -> Map Text AgentInfo -> [(FilePath, [(Text, ClaimState)])]
findCoClaimedFiles files _hash otherAgents =
  [ (fp, claimers)
  | fp <- files
  , let claimers = findClaimers fp otherAgents
  , not (null claimers)
  ]

-- | Check if all co-claimers for a file have staged
allCoClaimersStaged :: (FilePath, [(Text, ClaimState)]) -> Bool
allCoClaimersStaged (_, claimers) = all (claimStaged . snd) claimers

-- | Find what other agents an agent is waiting on
findWaitingOn :: [FilePath] -> Text -> Registry -> [(Text, FilePath)]
findWaitingOn files hash reg =
  let otherAgents = Map.delete hash reg
  in [ (otherHash, fp)
     | fp <- files
     , (otherHash, cs) <- findClaimers fp otherAgents
     , not (claimStaged cs)
     ]

-- | List all agents
cmdList :: IO ()
cmdList = do
  reg <- readRegistry
  printJSON $ encode $ object
    [ "ok"     .= True
    , "agents" .= reg
    ]

-- | Cleanup an agent
cmdCleanup :: Text -> IO ()
cmdCleanup hash = do
  -- Unclaim all files
  modifyRegistry $ \reg -> do
    let reg' = Map.delete hash reg
    return (reg', ())

  -- Release all reservations held by this agent
  withMkdirLock reserveLockDir 5.0 $ do
    reservations <- readReservations
    let mine = Map.filter (\r -> resHolder r == hash) reservations
    let reservations' = Map.difference reservations mine
    writeReservations reservations'
    mapM_ (\res -> sendMessage hash Release ("Released " <> res) (Just res))
          (Map.keys mine)

  -- Send leave message
  _ <- sendMessage hash Status ("Agent " <> hash <> " left") Nothing

  -- Remove agent directory
  _ <- try (removeDirectoryRecursive (agentDir hash)) :: IO (Either SomeException ())

  printJSON $ encode $ object
    [ "ok"   .= True
    , "hash" .= hash
    ]

-- Reservation helpers

readResources :: IO Resources
readResources = do
  result <- try (BS.readFile resourcesPath) :: IO (Either SomeException BS.ByteString)
  case result of
    Left _  -> return Map.empty
    Right bs -> case eitherDecodeStrict' bs of
      Left _  -> return Map.empty
      Right r -> return r

readReservations :: IO Reservations
readReservations = do
  result <- try (BS.readFile reservationsPath) :: IO (Either SomeException BS.ByteString)
  case result of
    Left _  -> return Map.empty
    Right bs -> case eitherDecodeStrict' bs of
      Left _  -> return Map.empty
      Right r -> return r

writeReservations :: Reservations -> IO ()
writeReservations res = do
  let tmpPath = reservationsPath <.> "tmp"
  BL.writeFile tmpPath (encode res)
  renameFileCompat tmpPath reservationsPath

renameFileCompat :: FilePath -> FilePath -> IO ()
renameFileCompat src dst = do
  -- On Windows, rename can fail if dst exists; remove first
  _ <- try (removeFile dst) :: IO (Either SomeException ())
  renameFile src dst

isExpired :: UTCTime -> Reservation -> Bool
isExpired now r =
  let elapsed = realToFrac (diffUTCTime now (resAcquired r)) :: Double
  in elapsed > fromIntegral (resTtl r)

-- | Reserve a shared resource
cmdReserve :: Text -> Text -> Maybe Int -> Int -> IO ()
cmdReserve hash resource mbTtl timeoutSec = do
  resources <- readResources
  case Map.lookup resource resources of
    Nothing -> do
      printError $ "WARNING: Unknown resource: " ++ T.unpack resource
      printError $ "Available resources: " ++ show (Map.keys resources)
      jsonError ("Unknown resource: " <> resource)
      exitWithCode exitGeneral
    Just resDef -> do
      let ttl = maybe (resDefaultTtl resDef) id mbTtl
      reserveLoop hash resource ttl timeoutSec

reserveLoop :: Text -> Text -> Int -> Int -> IO ()
reserveLoop hash resource ttl timeoutSec = go (timeoutSec * 2)  -- 500ms intervals
  where
    go 0 = do
      -- Final attempt
      result <- tryReserve hash resource ttl
      case result of
        Right () -> return ()
        Left (holder, remaining) -> do
          printError $ "WARNING: Timed out waiting for " ++ T.unpack resource
            ++ " (held by " ++ T.unpack holder
            ++ ", " ++ show remaining ++ "s remaining)."
          jsonError ("Timed out waiting for " <> resource)
          exitWithCode exitLockTimeout
    go remaining = do
      result <- tryReserve hash resource ttl
      case result of
        Right () -> return ()
        Left _ -> do
          threadDelay 500000  -- 500ms
          go (remaining - 1)

tryReserve :: Text -> Text -> Int -> IO (Either (Text, Int) ())
tryReserve hash resource ttl = do
  withMkdirLock reserveLockDir 5.0 $ do
    now <- getCurrentTime
    reservations <- readReservations
    case Map.lookup resource reservations of
      Nothing -> do
        -- Unreserved, take it
        let r = Reservation hash now ttl Nothing
        writeReservations (Map.insert resource r reservations)
        _ <- sendMessage hash Reserve ("Reserved " <> resource) (Just resource)
        printJSON $ encode $ object
          [ "ok"       .= True
          , "resource" .= resource
          , "ttl"      .= ttl
          ]
        return (Right ())
      Just existing
        | resHolder existing == hash -> do
            -- Already ours, refresh TTL
            let r = existing { resAcquired = now, resTtl = ttl }
            writeReservations (Map.insert resource r reservations)
            printJSON $ encode $ object
              [ "ok"       .= True
              , "resource" .= resource
              , "ttl"      .= ttl
              , "refreshed" .= True
              ]
            return (Right ())
        | isExpired now existing -> do
            -- Expired, steal it
            printError $ "WARNING: Stale reservation from " ++ T.unpack (resHolder existing)
              ++ " expired. Taking over."
            let r = Reservation hash now ttl Nothing
            writeReservations (Map.insert resource r reservations)
            _ <- sendMessage hash Reserve
              ("Reserved " <> resource <> " (expired from " <> resHolder existing <> ")")
              (Just resource)
            printJSON $ encode $ object
              [ "ok"       .= True
              , "resource" .= resource
              , "ttl"      .= ttl
              ]
            return (Right ())
        | otherwise -> do
            -- Held by someone else, still valid
            let elapsed = realToFrac (diffUTCTime now (resAcquired existing)) :: Double
            let remaining = resTtl existing - round elapsed
            return (Left (resHolder existing, remaining))

-- | Release a shared resource
cmdRelease :: Text -> Text -> IO ()
cmdRelease hash resource = do
  withMkdirLock reserveLockDir 5.0 $ do
    reservations <- readReservations
    case Map.lookup resource reservations of
      Nothing -> do
        -- Not reserved, no-op
        printJSON $ encode $ object
          [ "ok"       .= True
          , "resource" .= resource
          ]
      Just existing
        | resHolder existing == hash -> do
            writeReservations (Map.delete resource reservations)
            _ <- sendMessage hash Release ("Released " <> resource) (Just resource)
            printJSON $ encode $ object
              [ "ok"       .= True
              , "resource" .= resource
              ]
        | otherwise -> do
            printError $ "WARNING: " ++ T.unpack resource ++ " is held by "
              ++ T.unpack (resHolder existing) ++ ", not you."
            jsonError (resource <> " is held by " <> resHolder existing <> ", not you")
            exitWithCode exitGeneral

-- | Show all reservations
cmdReservations :: IO ()
cmdReservations = do
  resources <- readResources
  reservations <- readReservations
  now <- getCurrentTime

  -- Clean up expired reservations
  let (expired, active) = Map.partitionWithKey
        (\k _ -> case Map.lookup k reservations of
          Just r  -> isExpired now r
          Nothing -> False)
        reservations

  -- Write cleaned up reservations if any expired
  if not (Map.null expired)
    then writeReservations (Map.difference reservations expired)
    else return ()

  let entries = map (buildResEntry now active) (Map.toList resources)
  printJSON $ encode $ object
    [ "ok"        .= True
    , "resources" .= entries
    ]

buildResEntry :: UTCTime -> Reservations -> (Text, ResourceDef) -> Value
buildResEntry now reservations (name, def) =
  case Map.lookup name reservations of
    Nothing -> object
      [ "name"        .= name
      , "description" .= resDescription def
      , "status"      .= ("available" :: Text)
      ]
    Just r
      | isExpired now r -> object
          [ "name"        .= name
          , "description" .= resDescription def
          , "status"      .= ("available" :: Text)
          ]
      | otherwise ->
          let elapsed = realToFrac (diffUTCTime now (resAcquired r)) :: Double
              remaining = resTtl r - round elapsed
          in object
            [ "name"        .= name
            , "description" .= resDescription def
            , "status"      .= ("reserved" :: Text)
            , "holder"      .= resHolder r
            , "remaining"   .= (remaining :: Int)
            ]

-- | Tee stdin to stdout and output.log
cmdTee :: Text -> IO ()
cmdTee hash = do
  let logPath = outputLog hash
  go logPath
  where
    go logPath = do
      result <- try (BS8.hGetLine stdin) :: IO (Either SomeException BS8.ByteString)
      case result of
        Left _ -> return ()  -- EOF or error
        Right line -> do
          BS8.hPutStrLn stdout line
          hFlush stdout
          BS8.appendFile logPath (line <> "\n")
          go logPath
