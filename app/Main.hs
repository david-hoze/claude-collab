module Main where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitWith, ExitCode(..))
import Control.Exception (SomeException, catch)

import ClaudeCollab.Commands
import ClaudeCollab.Types (MessageType(..))

data Command
  = Init Text
  | Send Text Text MessageType (Maybe Text)
  | Read Text Bool Int
  | Watch Text
  | FilesClaim Text [FilePath] Bool
  | FilesUnclaim Text [FilePath]
  | FilesStatus
  | CommitCmd Text Text
  | ReserveCmd Text Text (Maybe Int) Int
  | ReleaseCmd Text Text
  | ReservationsCmd
  | List
  | Cleanup Text
  | Tee Text
  deriving (Show)

parseMessageType :: ReadM MessageType
parseMessageType = eitherReader $ \s -> case s of
  "chat"    -> Right Chat
  "status"  -> Right Status
  "claim"   -> Right Claim
  "unclaim" -> Right Unclaim
  "staged"  -> Right Staged
  "commit"  -> Right Commit
  "reserve" -> Right Reserve
  "release" -> Right Release
  _         -> Left $ "Unknown message type: " ++ s

commandParser :: Parser Command
commandParser = hsubparser
  ( command "init" (info initParser (progDesc "Initialize an agent"))
  <> command "send" (info sendParser (progDesc "Send a channel message"))
  <> command "read" (info readParser (progDesc "Read channel messages"))
  <> command "watch" (info watchParser (progDesc "Watch channel messages"))
  <> command "files" (info filesParser (progDesc "File claim operations"))
  <> command "commit" (info commitParser (progDesc "Commit claimed files"))
  <> command "reserve" (info reserveParser (progDesc "Reserve a shared resource"))
  <> command "release" (info releaseParser (progDesc "Release a shared resource"))
  <> command "reservations" (info reservationsParser (progDesc "Show resource reservations"))
  <> command "list" (info listParser (progDesc "List all agents"))
  <> command "cleanup" (info cleanupParser (progDesc "Clean up an agent"))
  <> command "tee" (info teeParser (progDesc "Tee stdin to stdout and log"))
  )

initParser :: Parser Command
initParser = Init
  <$> argument (T.pack <$> str) (metavar "HASH")

sendParser :: Parser Command
sendParser = Send
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> argument (T.pack <$> str) (metavar "MESSAGE")
  <*> option parseMessageType
      ( long "type"
      <> value Chat
      <> metavar "TYPE"
      <> help "Message type: chat|status|claim|unclaim|staged|commit" )
  <*> optional (option (T.pack <$> str)
      ( long "target"
      <> metavar "FILE"
      <> help "Target file" ))

readParser :: Parser Command
readParser = Read
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> switch (long "wait" <> help "Wait for new messages")
  <*> option auto
      ( long "timeout"
      <> value 60
      <> metavar "SECONDS"
      <> help "Timeout for --wait (default 60)" )

watchParser :: Parser Command
watchParser = Watch
  <$> argument (T.pack <$> str) (metavar "HASH")

filesParser :: Parser Command
filesParser = hsubparser
  ( command "claim" (info filesClaimParser (progDesc "Claim files"))
  <> command "unclaim" (info filesUnclaimParser (progDesc "Unclaim files"))
  <> command "status" (info filesStatusParser (progDesc "Show file status"))
  )

filesClaimParser :: Parser Command
filesClaimParser = FilesClaim
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> some (argument str (metavar "PATH..."))
  <*> switch (long "shared" <> help "Allow co-claiming with another agent")

filesUnclaimParser :: Parser Command
filesUnclaimParser = FilesUnclaim
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> some (argument str (metavar "PATH..."))

filesStatusParser :: Parser Command
filesStatusParser = pure FilesStatus

commitParser :: Parser Command
commitParser = CommitCmd
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> option (T.pack <$> str)
      ( short 'm'
      <> metavar "MESSAGE"
      <> help "Commit message" )

reserveParser :: Parser Command
reserveParser = ReserveCmd
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> argument (T.pack <$> str) (metavar "RESOURCE")
  <*> optional (option auto
      ( long "ttl"
      <> metavar "SECONDS"
      <> help "TTL in seconds (default from resources.json)" ))
  <*> option auto
      ( long "timeout"
      <> value 30
      <> metavar "SECONDS"
      <> help "Timeout waiting for resource (default 30)" )

releaseParser :: Parser Command
releaseParser = ReleaseCmd
  <$> argument (T.pack <$> str) (metavar "HASH")
  <*> argument (T.pack <$> str) (metavar "RESOURCE")

reservationsParser :: Parser Command
reservationsParser = pure ReservationsCmd

listParser :: Parser Command
listParser = pure List

cleanupParser :: Parser Command
cleanupParser = Cleanup
  <$> argument (T.pack <$> str) (metavar "HASH")

teeParser :: Parser Command
teeParser = Tee
  <$> argument (T.pack <$> str) (metavar "HASH")

opts :: ParserInfo Command
opts = info (commandParser <**> helper)
  ( fullDesc
  <> progDesc "Multi-agent coordination tool for Claude Code"
  <> header "claude-collab - coordinate multiple Claude Code agents" )

main :: IO ()
main = do
  cmd <- execParser opts
  runCommand cmd `catch` \(e :: SomeException) -> do
    putStrLn $ "{\"ok\":false,\"error\":" ++ show (show e) ++ "}"
    exitWith (ExitFailure 1)

runCommand :: Command -> IO ()
runCommand (Init hash)                      = cmdInit hash
runCommand (Send hash msg ty target)        = cmdSend hash msg ty target
runCommand (Read hash wait timeout)         = cmdRead hash wait timeout
runCommand (Watch hash)                     = cmdWatch hash
runCommand (FilesClaim hash paths shared)   = cmdFilesClaim hash paths shared
runCommand (FilesUnclaim hash paths)        = cmdFilesUnclaim hash paths
runCommand FilesStatus                      = cmdFilesStatus
runCommand (CommitCmd hash msg)             = cmdCommit hash msg
runCommand (ReserveCmd hash res ttl to)     = cmdReserve hash res ttl to
runCommand (ReleaseCmd hash res)            = cmdRelease hash res
runCommand ReservationsCmd                  = cmdReservations
runCommand List                             = cmdList
runCommand (Cleanup hash)                   = cmdCleanup hash
runCommand (Tee hash)                       = cmdTee hash
