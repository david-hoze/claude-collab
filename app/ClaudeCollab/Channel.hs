module ClaudeCollab.Channel
  ( sendMessage
  , readMessages
  , readMessagesWait
  , watchMessages
  , readSeq
  , readCursor
  , writeCursor
  , messageFilePath
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import Data.Time (getCurrentTime)
import System.Directory (renameFile)
import System.FilePath ((</>))
import Text.Printf (printf)

import ClaudeCollab.Lock
import ClaudeCollab.Types
import ClaudeCollab.Watcher

-- | Read the current sequence number (default 0).
readSeq :: IO Int
readSeq = do
  result <- try (readFile seqFile) :: IO (Either SomeException String)
  case result of
    Left _  -> return 0
    Right s -> case reads (filter (/= '\n') s) of
      [(n, "")] -> return n
      _         -> return 0

-- | Write the sequence number.
writeSeq :: Int -> IO ()
writeSeq n = writeFile seqFile (show n)

-- | Read an agent's cursor (default 0).
readCursor :: Text -> IO Int
readCursor hash = do
  let path = cursorFile hash
  result <- try (readFile path) :: IO (Either SomeException String)
  case result of
    Left _  -> return 0
    Right s -> case reads (filter (/= '\n') s) of
      [(n, "")] -> return n
      _         -> return 0

-- | Write an agent's cursor.
writeCursor :: Text -> Int -> IO ()
writeCursor hash n = writeFile (cursorFile hash) (show n)

-- | Format a sequence number as a filename: "000042.json"
messageFileName :: Int -> String
messageFileName n = printf "%06d.json" n

-- | Full path to a message file.
messageFilePath :: Int -> FilePath
messageFilePath n = channelDir </> messageFileName n

-- | Send a message to the channel. Returns the sequence number.
sendMessage :: Text -> MessageType -> Text -> Maybe Text -> IO Int
sendMessage from msgtype msg target = do
  -- Acquire channel lock, increment seq
  n <- withMkdirLock channelLockDir 5.0 $ do
    cur <- readSeq
    let next = cur + 1
    writeSeq next
    return next

  -- Build message
  now <- getCurrentTime
  let message = Message
        { msgSeq    = n
        , msgTs     = now
        , msgFrom   = from
        , msgType   = msgtype
        , msgMsg    = msg
        , msgTarget = target
        }

  -- Write atomically: temp file then rename
  let finalPath = messageFilePath n
      tmpPath   = finalPath ++ ".tmp"
  BL.writeFile tmpPath (encode message)
  renameFile tmpPath finalPath

  return n

-- | Read messages from cursor+1 to latest. Returns (messages, new_cursor).
-- Filters out the agent's own messages so they don't obscure messages from
-- other agents. The cursor advances only to the last successfully read seq,
-- stopping at gaps to avoid skipping files not yet written.
readMessages :: Text -> IO ([Message], Int)
readMessages hash = do
  cursor <- readCursor hash
  latest <- readSeq
  if cursor >= latest
    then return ([], cursor)
    else do
      (allMsgs, lastRead) <- readRange (cursor + 1) latest
      let otherMsgs = filter (\m -> msgFrom m /= hash) allMsgs
      writeCursor hash lastRead
      return (otherMsgs, lastRead)

-- | Read a range of message files. Stops at the first gap (missing or
-- unreadable file) to avoid skipping messages that haven't been written yet.
-- Returns (messages, lastSuccessfullyReadSeq).
readRange :: Int -> Int -> IO ([Message], Int)
readRange from to
  | from > to = return ([], from - 1)
  | otherwise = do
      let path = messageFilePath from
      result <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
      case result of
        Left _ -> return ([], from - 1)  -- gap: stop here
        Right bs -> case eitherDecodeStrict' bs of
          Left _    -> return ([], from - 1)  -- corrupt: stop here
          Right msg -> do
            (rest, lastRead) <- readRange (from + 1) to
            return (msg : rest, lastRead)

-- | Read messages, waiting if none are available.
-- Uses fsnotify to watch for new message files, with a 5-second fallback poll.
readMessagesWait :: Text -> Int -> IO ([Message], Int)
readMessagesWait hash timeoutSec = do
  -- Immediate check
  (msgs, cur) <- readMessages hash
  if not (null msgs)
    then return (msgs, cur)
    else withWatcher channelDir timeoutSec (readMessages hash)

-- | Watch for new messages continuously, calling the callback for each.
-- Uses fsnotify with a 5-second fallback poll. Never returns.
watchMessages :: Text -> (Message -> IO ()) -> IO ()
watchMessages hash callback =
  withWatcherForever channelDir $ do
    (msgs, _) <- readMessages hash
    mapM_ callback msgs
