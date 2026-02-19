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

import Control.Concurrent (threadDelay)
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
readMessages :: Text -> IO ([Message], Int)
readMessages hash = do
  cursor <- readCursor hash
  latest <- readSeq
  if cursor >= latest
    then return ([], cursor)
    else do
      msgs <- readRange (cursor + 1) latest
      writeCursor hash latest
      return (msgs, latest)

-- | Read a range of message files.
readRange :: Int -> Int -> IO [Message]
readRange from to
  | from > to = return []
  | otherwise = do
      let path = messageFilePath from
      result <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
      rest <- readRange (from + 1) to
      case result of
        Left _   -> return rest
        Right bs -> case eitherDecodeStrict' bs of
          Left _    -> return rest
          Right msg -> return (msg : rest)

-- | Read messages, waiting if none are available. Polls every 500ms.
-- Falls back to polling since fsnotify can be tricky on some platforms.
readMessagesWait :: Text -> Int -> IO ([Message], Int)
readMessagesWait hash timeoutSec = do
  (msgs, cur) <- readMessages hash
  if not (null msgs)
    then return (msgs, cur)
    else pollLoop (timeoutSec * 2)  -- 500ms intervals
  where
    pollLoop :: Int -> IO ([Message], Int)
    pollLoop 0 = do
      cur <- readCursor hash
      return ([], cur)
    pollLoop remaining = do
      threadDelay 500000  -- 500ms
      (msgs, cur) <- readMessages hash
      if not (null msgs)
        then return (msgs, cur)
        else pollLoop (remaining - 1)

-- | Watch for new messages continuously, calling the callback for each.
-- This is a long-running operation.
watchMessages :: Text -> (Message -> IO ()) -> IO ()
watchMessages hash callback = go
  where
    go = do
      (msgs, _) <- readMessages hash
      mapM_ callback msgs
      threadDelay 500000  -- 500ms poll
      go
