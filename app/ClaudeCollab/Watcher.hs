module ClaudeCollab.Watcher
  ( withWatcher
  , withWatcherForever
  , isMessageFile
  ) where

import Control.Concurrent (MVar, newEmptyMVar, takeMVar, tryPutMVar,
                           forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (void, forever)
import Data.Char (isDigit)
import Data.Time (getCurrentTime, diffUTCTime)
import System.FilePath (takeFileName)
import System.FSNotify (eventPath, watchDir, withManager)

-- | Check if a filename looks like a message file: 6 digits + ".json", no ".tmp".
isMessageFile :: FilePath -> Bool
isMessageFile name =
  let base = takeFileName name
  in length base == 11
     && all isDigit (take 6 base)
     && drop 6 base == ".json"

-- | Watch a directory for new message files. Runs the action on each event.
-- Falls back to polling every 5 seconds to catch missed events.
-- Returns the action's result when non-empty, or the last-try result on timeout.
withWatcher :: FilePath       -- ^ Directory to watch
            -> Int            -- ^ Timeout in seconds
            -> IO ([a], Int)  -- ^ Action to run on each event
            -> IO ([a], Int)  -- ^ Result (empty on timeout)
withWatcher dir timeoutSec action = do
  signal <- newEmptyMVar :: IO (MVar ())

  -- Start fsnotify watcher + fallback poll + timeout
  withManager $ \mgr -> do
    -- Watch for new message files
    stopWatch <- watchDir mgr dir (isMessageFile . eventPath) $ \_ ->
      void (tryPutMVar signal ())

    -- Fallback poll thread: signal every 5 seconds
    fallbackTid <- forkIO $ forever $ do
      threadDelay 5000000  -- 5 seconds
      void (tryPutMVar signal ())

    -- Timeout thread
    timeoutTid <- forkIO $ do
      threadDelay (timeoutSec * 1000000)
      void (tryPutMVar signal ())

    -- Main loop — use wall clock to track remaining time
    startTime <- getCurrentTime
    let loop = do
          takeMVar signal
          now <- getCurrentTime
          let elapsed = realToFrac (diffUTCTime now startTime) :: Double
          if elapsed >= fromIntegral timeoutSec
            then do
              cleanup stopWatch fallbackTid timeoutTid
              action  -- one last try
            else do
              (msgs, cur) <- action
              if not (null msgs)
                then do
                  cleanup stopWatch fallbackTid timeoutTid
                  return (msgs, cur)
                else loop  -- self-wake (own messages filtered), keep waiting

    loop
  where
    cleanup stopWatch fallbackTid timeoutTid = do
      _ <- stopWatch
      killThread fallbackTid
      _ <- try (killThread timeoutTid) :: IO (Either SomeException ())
      return ()

-- | Watch a directory forever, calling the action on each event.
-- Never returns (runs until the process is killed).
withWatcherForever :: FilePath       -- ^ Directory to watch
                   -> IO ()          -- ^ Action to run on each event
                   -> IO ()
withWatcherForever dir action = do
  signal <- newEmptyMVar :: IO (MVar ())

  withManager $ \mgr -> do
    _stopWatch <- watchDir mgr dir (isMessageFile . eventPath) $ \_ ->
      void (tryPutMVar signal ())

    -- Fallback poll every 5 seconds
    _fallbackTid <- forkIO $ forever $ do
      threadDelay 5000000
      void (tryPutMVar signal ())

    -- Main loop: block on signal, run action, repeat
    forever $ do
      takeMVar signal
      action
