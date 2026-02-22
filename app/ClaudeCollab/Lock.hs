module ClaudeCollab.Lock
  ( withMkdirLock
  , acquireLock
  , releaseLock
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket_, try)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import System.Directory (createDirectory, getModificationTime, removeDirectory)

-- | Acquire a mkdir-based lock. Spins every 20ms, force-breaks after staleSeconds.
-- Hard wall-clock timeout at 3x staleSeconds to prevent infinite spin
-- (e.g. on Windows where lock dir mtime can be refreshed by the OS).
acquireLock :: FilePath -> Double -> IO ()
acquireLock lockPath staleSeconds = do
  deadline <- getCurrentTime
  let timeoutSeconds = staleSeconds * 3
  go deadline timeoutSeconds
  where
    go startTime timeoutSecs = do
      result <- try (createDirectory lockPath) :: IO (Either SomeException ())
      case result of
        Right () -> return ()  -- acquired
        Left _   -> do
          now <- getCurrentTime
          let elapsed = realToFrac (diffUTCTime now startTime) :: Double
          if elapsed > timeoutSecs
            then do
              -- Hard timeout — force-break and take it
              _ <- try (removeDirectory lockPath) :: IO (Either SomeException ())
              result2 <- try (createDirectory lockPath) :: IO (Either SomeException ())
              case result2 of
                Right () -> return ()
                Left _   -> error $ "acquireLock: failed to acquire " ++ lockPath
                  ++ " after " ++ show (round timeoutSecs :: Int) ++ "s"
            else do
              -- Check if lock is stale
              mtime <- tryGetMtime lockPath
              case mtime of
                Just t | realToFrac (diffUTCTime now t) > staleSeconds -> do
                  -- Stale lock, force-break
                  _ <- try (removeDirectory lockPath) :: IO (Either SomeException ())
                  go startTime timeoutSecs
                _ -> do
                  threadDelay 20000  -- 20ms
                  go startTime timeoutSecs

    tryGetMtime :: FilePath -> IO (Maybe UTCTime)
    tryGetMtime p = do
      result <- try (getModificationTime p) :: IO (Either SomeException UTCTime)
      case result of
        Right t  -> return (Just t)
        Left _   -> return Nothing

-- | Release a mkdir-based lock.
releaseLock :: FilePath -> IO ()
releaseLock lockPath = do
  _ <- try (removeDirectory lockPath) :: IO (Either SomeException ())
  return ()

-- | Bracket pattern: acquire lock, run action, release lock.
withMkdirLock :: FilePath -> Double -> IO a -> IO a
withMkdirLock lockPath staleSeconds =
  bracket_ (acquireLock lockPath staleSeconds) (releaseLock lockPath)
