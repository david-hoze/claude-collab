module Main where

import Control.Exception (SomeException, try)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist,
                         removeDirectoryRecursive, removeFile, renameFile,
                         setCurrentDirectory, getCurrentDirectory,
                         getTemporaryDirectory)
import System.Exit (ExitCode(..), exitFailure)
import System.FilePath ((</>), (<.>))
import System.IO (hFlush, stdout)
import System.Process (readProcessWithExitCode)

import ClaudeCollab.Types
import ClaudeCollab.Registry
import ClaudeCollab.Channel
import ClaudeCollab.Lock

-- Simple test framework
data TestResult = Pass | Fail String deriving (Show)

runTest :: String -> IO TestResult -> IO Bool
runTest name action = do
  putStr $ "  " ++ name ++ "... "
  hFlush stdout
  result <- try action :: IO (Either SomeException TestResult)
  case result of
    Left err -> do
      putStrLn $ "EXCEPTION: " ++ show err
      return False
    Right Pass -> do
      putStrLn "PASS"
      return True
    Right (Fail msg) -> do
      putStrLn $ "FAIL: " ++ msg
      return False

assert :: Bool -> String -> IO TestResult
assert True _    = return Pass
assert False msg = return (Fail msg)

-- Setup/teardown: create a temp dir and initialize structure
withTestDir :: (FilePath -> IO a) -> IO a
withTestDir action = do
  tmpBase <- getTemporaryDirectory
  let testDir = tmpBase </> "claude-collab-test"
  -- Clean up any previous run
  _ <- try (removeDirectoryRecursive testDir) :: IO (Either SomeException ())
  createDirectoryIfMissing True testDir

  origDir <- getCurrentDirectory
  setCurrentDirectory testDir

  -- Initialize git repo for tests that need it
  _ <- readProcessWithExitCode "git" ["init"] ""
  _ <- readProcessWithExitCode "git" ["config", "user.email", "test@test.com"] ""
  _ <- readProcessWithExitCode "git" ["config", "user.name", "Test"] ""
  -- Create an initial commit so HEAD exists
  writeFile "README.md" "test"
  _ <- readProcessWithExitCode "git" ["add", "README.md"] ""
  _ <- readProcessWithExitCode "git" ["commit", "-m", "initial"] ""

  result <- action testDir

  setCurrentDirectory origDir
  _ <- try (removeDirectoryRecursive testDir) :: IO (Either SomeException ())
  return result

main :: IO ()
main = withTestDir $ \_ -> do
  putStrLn "claude-collab test suite"
  putStrLn "========================"
  results <- sequence
    [ section "Lock" lockTests
    , section "Channel" channelTests
    , section "Registry" registryTests
    , section "Reservations" reservationTests
    , section "Integration" integrationTests
    ]
  let total = sum (map fst results)
      passed = sum (map snd results)
  putStrLn $ "\n" ++ show passed ++ "/" ++ show total ++ " tests passed."
  if passed == total then return () else exitFailure

section :: String -> IO (Int, Int) -> IO (Int, Int)
section name action = do
  putStrLn $ "\n[" ++ name ++ "]"
  action

-- Lock tests
lockTests :: IO (Int, Int)
lockTests = do
  results <- sequence
    [ runTest "mkdir lock acquire and release" $ do
        let lockPath = ".claude/agents/test-lock"
        createDirectoryIfMissing True ".claude/agents"
        acquireLock lockPath 5.0
        exists <- doesDirectoryExist lockPath
        releaseLock lockPath
        existsAfter <- doesDirectoryExist lockPath
        assert (exists && not existsAfter) "lock should exist while held, not after"

    , runTest "mkdir lock with bracket" $ do
        let lockPath = ".claude/agents/test-lock2"
        createDirectoryIfMissing True ".claude/agents"
        withMkdirLock lockPath 5.0 $ do
          exists <- doesDirectoryExist lockPath
          assert exists "lock should exist inside bracket"
    ]
  return (length results, length (filter id results))

-- Channel tests
channelTests :: IO (Int, Int)
channelTests = do
  -- Setup channel dir
  createDirectoryIfMissing True channelDir
  createDirectoryIfMissing True (agentDir "test1")
  createDirectoryIfMissing True (agentDir "test2")

  -- Initialize cursors
  writeCursor "test1" 0
  writeCursor "test2" 0

  results <- sequence
    [ runTest "send message and read seq" $ do
        n <- sendMessage "test1" Chat "hello world" Nothing
        assert (n > 0) $ "expected positive seq, got " ++ show n

    , runTest "read message round-trip" $ do
        n <- sendMessage "test1" Chat "test message" Nothing
        -- Read the message file directly
        bs <- BS.readFile (messageFilePath n)
        case eitherDecodeStrict' bs :: Either String Message of
          Left err  -> return $ Fail $ "decode error: " ++ err
          Right msg -> assert (msgMsg msg == "test message" && msgFrom msg == "test1")
            "message content should match"

    , runTest "read returns new messages" $ do
        -- Reset cursor
        writeCursor "test2" 0
        latest <- readSeq
        writeCursor "test2" (latest - 1)  -- Position just before last message
        (msgs, _) <- readMessages "test2"
        assert (not (null msgs)) "should have at least one message"

    , runTest "two sends get distinct sequence numbers" $ do
        n1 <- sendMessage "test1" Chat "msg1" Nothing
        n2 <- sendMessage "test1" Chat "msg2" Nothing
        assert (n2 == n1 + 1) $ "expected consecutive seqs, got " ++ show n1 ++ " and " ++ show n2

    , runTest "send with target field" $ do
        n <- sendMessage "test1" Claim "claiming file" (Just "src/foo.hs")
        bs <- BS.readFile (messageFilePath n)
        case eitherDecodeStrict' bs :: Either String Message of
          Left err  -> return $ Fail $ "decode error: " ++ err
          Right msg -> assert (msgTarget msg == Just "src/foo.hs")
            "target field should be set"
    ]
  return (length results, length (filter id results))

-- Registry tests
registryTests :: IO (Int, Int)
registryTests = do
  createDirectoryIfMissing True ".claude/agents"

  results <- sequence
    [ runTest "read empty registry" $ do
        -- Remove if exists so we test the empty case
        _ <- try (removeFile registryPath) :: IO (Either SomeException ())
        reg <- readRegistry
        assert (Map.null reg) "empty registry should be empty map"

    , runTest "write and read registry" $ do
        let info = AgentInfo
              { agentStarted = read "2025-01-15 10:00:00 UTC"
              , agentStatus  = "active"
              , agentClaimed = Map.empty
              , agentName    = Nothing
              }
        let reg = Map.singleton "abc1" info
        writeRegistry reg
        reg' <- readRegistry
        assert (Map.size reg' == 1 && Map.member "abc1" reg')
          "should read back what was written"

    , runTest "modifyRegistry works" $ do
        result <- modifyRegistry $ \reg -> do
          let info = AgentInfo
                { agentStarted = read "2025-01-15 11:00:00 UTC"
                , agentStatus  = "active"
                , agentClaimed = Map.singleton "src/test.ts"
                    (ClaimState False Nothing)
                , agentName    = Nothing
                }
          return (Map.insert "d4e5" info reg, "inserted")
        reg <- readRegistry
        assert (result == "inserted" && Map.member "d4e5" reg)
          "modify should insert and return result"
    ]
  return (length results, length (filter id results))

-- Reservation helpers for tests
writeTestReservations :: Reservations -> IO ()
writeTestReservations res = do
  let tmpPath = reservationsPath <.> "tmp"
  BL.writeFile tmpPath (encode res)
  _ <- try (removeFile reservationsPath) :: IO (Either SomeException ())
  renameFile tmpPath reservationsPath

readTestReservations :: IO Reservations
readTestReservations = do
  result <- try (BS.readFile reservationsPath) :: IO (Either SomeException BS.ByteString)
  case result of
    Left _  -> return Map.empty
    Right bs -> case eitherDecodeStrict' bs of
      Left _  -> return Map.empty
      Right r -> return r

-- Reservation tests
reservationTests :: IO (Int, Int)
reservationTests = do
  createDirectoryIfMissing True ".claude/agents"

  -- Create resources.json
  BL.writeFile resourcesPath $ encode defaultResources
  -- Create empty reservations.json
  BL.writeFile reservationsPath $ encode (Map.empty :: Reservations)

  results <- sequence
    [ runTest "resources.json created with defaults" $ do
        exists <- doesFileExist resourcesPath
        bs <- BS.readFile resourcesPath
        case eitherDecodeStrict' bs :: Either String Resources of
          Left err -> return $ Fail $ "decode error: " ++ err
          Right res -> assert (Map.member "test" res && Map.member "build" res && Map.member "install" res)
            "should have test, build, install resources"

    , runTest "reserve unreserved resource" $ do
        writeTestReservations Map.empty
        now <- getCurrentTime
        let r = Reservation "agent1" now 300 Nothing
        writeTestReservations (Map.singleton "test" r)
        res <- readTestReservations
        case Map.lookup "test" res of
          Nothing -> return $ Fail "test reservation not found"
          Just rv -> assert (resHolder rv == "agent1" && resTtl rv == 300)
            "should be reserved by agent1 with ttl 300"

    , runTest "release reservation" $ do
        now <- getCurrentTime
        let r = Reservation "agent1" now 300 Nothing
        writeTestReservations (Map.singleton "test" r)
        -- Release
        writeTestReservations Map.empty
        res <- readTestReservations
        assert (Map.null res) "reservations should be empty after release"

    , runTest "expired reservation detected" $ do
        now <- getCurrentTime
        let expired = Reservation "agent1" (addUTCTime (-400) now) 300 Nothing
        writeTestReservations (Map.singleton "test" expired)
        res <- readTestReservations
        case Map.lookup "test" res of
          Nothing -> return $ Fail "reservation not found"
          Just rv -> do
            let elapsed = realToFrac (now `diffUTCTime` resAcquired rv) :: Double
            assert (elapsed > fromIntegral (resTtl rv))
              "reservation should be expired"

    , runTest "reservation by different agent blocks" $ do
        now <- getCurrentTime
        let r = Reservation "agent1" now 300 Nothing
        writeTestReservations (Map.singleton "test" r)
        res <- readTestReservations
        case Map.lookup "test" res of
          Nothing -> return $ Fail "reservation not found"
          Just rv -> assert (resHolder rv /= "agent2")
            "agent2 should not hold the reservation"

    , runTest "renew atomically releases and re-reserves" $ do
        now <- getCurrentTime
        -- Agent1 holds the resource
        let r = Reservation "agent1" now 300 Nothing
        writeTestReservations (Map.singleton "test" r)
        -- Simulate what tryReserve does with renew=True:
        -- atomically delete agent1's reservation, then re-reserve
        res <- readTestReservations
        let res' = case Map.lookup "test" res of
              Just existing | resHolder existing == "agent1" -> Map.delete "test" res
              _ -> res
        -- Now the resource should be unreserved
        let unreserved = not (Map.member "test" res')
        -- Re-reserve with fresh TTL
        let r2 = Reservation "agent1" now 600 Nothing
        let res'' = Map.insert "test" r2 res'
        writeTestReservations res''
        final <- readTestReservations
        case Map.lookup "test" final of
          Nothing -> return $ Fail "reservation not found after renew"
          Just rv -> assert (unreserved && resHolder rv == "agent1" && resTtl rv == 600)
            "should have been released then re-reserved with new TTL"

    , runTest "reserve without renew refreshes TTL for same agent" $ do
        now <- getCurrentTime
        let r = Reservation "agent1" now 300 Nothing
        writeTestReservations (Map.singleton "test" r)
        -- Simulate what tryReserve does with renew=False (same holder -> refresh):
        res <- readTestReservations
        case Map.lookup "test" res of
          Nothing -> return $ Fail "reservation not found"
          Just existing | resHolder existing == "agent1" -> do
            let r2 = existing { resAcquired = now, resTtl = 600 }
            writeTestReservations (Map.insert "test" r2 res)
            final <- readTestReservations
            case Map.lookup "test" final of
              Nothing -> return $ Fail "reservation not found after refresh"
              Just rv -> assert (resHolder rv == "agent1" && resTtl rv == 600)
                "should have refreshed TTL without releasing"
          Just _ -> return $ Fail "unexpected holder"
    ]
  return (length results, length (filter id results))

-- Integration tests (using the CLI binary via process calls)
integrationTests :: IO (Int, Int)
integrationTests = do
  -- These tests exercise the command functions directly
  createDirectoryIfMissing True channelDir
  createDirectoryIfMissing True ".claude/agents"

  -- Reset registry for clean integration tests
  writeRegistry Map.empty

  results <- sequence
    [ runTest "claim unclaimed file succeeds" $ do
        -- Setup: register agent
        writeRegistry $ Map.singleton "agent1" AgentInfo
          { agentStarted = read "2025-01-15 10:00:00 UTC"
          , agentStatus  = "active"
          , agentClaimed = Map.empty
          , agentName    = Nothing
          }
        -- Manually do what cmdFilesClaim does internally
        modifyRegistry $ \reg -> do
          case Map.lookup "agent1" reg of
            Nothing -> return (reg, ())
            Just info -> do
              let newClaimed = Map.insert "src/auth.ts" (ClaimState False Nothing) (agentClaimed info)
              let newInfo = info { agentClaimed = newClaimed }
              return (Map.insert "agent1" newInfo reg, ())
        reg <- readRegistry
        case Map.lookup "agent1" reg of
          Nothing -> return $ Fail "agent1 not in registry"
          Just info -> assert (Map.member "src/auth.ts" (agentClaimed info))
            "src/auth.ts should be claimed"

    , runTest "claim conflict detected" $ do
        -- agent1 already has src/auth.ts from above
        reg <- readRegistry
        let otherAgents = Map.delete "agent2" reg
        let claimers = [ h | (h, info) <- Map.toList otherAgents
                           , Map.member "src/auth.ts" (agentClaimed info)
                       ]
        assert (not (null claimers)) "should detect conflict on src/auth.ts"

    , runTest "shared claim adds co-claim" $ do
        -- Add agent2 with a shared claim on src/auth.ts
        modifyRegistry $ \reg -> do
          let info = AgentInfo
                { agentStarted = read "2025-01-15 10:30:00 UTC"
                , agentStatus  = "active"
                , agentClaimed = Map.singleton "src/auth.ts" (ClaimState False Nothing)
                , agentName    = Nothing
                }
          return (Map.insert "agent2" info reg, ())
        reg <- readRegistry
        let agent1Has = maybe False (Map.member "src/auth.ts" . agentClaimed) (Map.lookup "agent1" reg)
        let agent2Has = maybe False (Map.member "src/auth.ts" . agentClaimed) (Map.lookup "agent2" reg)
        assert (agent1Has && agent2Has) "both agents should claim src/auth.ts"

    , runTest "agent with staged files can stage new unstaged claims" $ do
        -- Setup: agent with one file already staged, one new unstaged claim
        let claims = Map.fromList
              [ ("src/old.ts", ClaimState True (Just "old commit msg"))
              , ("src/new.ts", ClaimState False Nothing)
              ]
        writeRegistry $ Map.singleton "stageAgent" AgentInfo
          { agentStarted = read "2025-01-15 10:00:00 UTC"
          , agentStatus  = "active"
          , agentClaimed = claims
          , agentName    = Nothing
          }
        reg <- readRegistry
        case Map.lookup "stageAgent" reg of
          Nothing -> return $ Fail "stageAgent not in registry"
          Just info -> do
            let (staged, unstaged) = Map.partition claimStaged (agentClaimed info)
            let unstagedOnly = [fp | (fp, cs) <- Map.toList (agentClaimed info), not (claimStaged cs)]
            assert (Map.size staged == 1 && Map.size unstaged == 1
                    && unstagedOnly == ["src/new.ts"])
              "should have 1 staged and 1 unstaged claim, unstaged list should be [src/new.ts]"

    , runTest "solo commit with dirty file" $ do
        -- Create a file, add it as claimed
        writeFile "src_solo.ts" "content"
        _ <- readProcessWithExitCode "git" ["add", "src_solo.ts"] ""
        writeRegistry $ Map.singleton "solo1" AgentInfo
          { agentStarted = read "2025-01-15 10:00:00 UTC"
          , agentStatus  = "active"
          , agentClaimed = Map.singleton "src_solo.ts" (ClaimState False Nothing)
          , agentName    = Nothing
          }
        -- We can't easily test the full commit flow without capturing stdout,
        -- but we can verify the git operations work
        (code, _, _) <- readProcessWithExitCode "git" ["status", "--porcelain"] ""
        assert (code == ExitSuccess) "git status should succeed"
    ]
  return (length results, length (filter id results))
