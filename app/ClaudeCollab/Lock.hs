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
acquireLock :: FilePath -> Double -> IO ()
acquireLock lockPath staleSeconds = go
  where
    go = do
      result <- try (createDirectory lockPath) :: IO (Either SomeException ())
      case result of
        Right () -> return ()  -- acquired
        Left _   -> do
          -- Check if lock is stale
          mtime <- tryGetMtime lockPath
          now <- getCurrentTime
          case mtime of
            Just t | realToFrac (diffUTCTime now t) > staleSeconds -> do
              -- Stale lock, force-break
              _ <- try (removeDirectory lockPath) :: IO (Either SomeException ())
              go
            _ -> do
              threadDelay 20000  -- 20ms
              go

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
