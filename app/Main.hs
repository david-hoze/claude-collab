module Main where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitWith, ExitCode(..))
import Control.Exception (SomeException, catch)

import ClaudeCollab.Commands
import ClaudeCollab.Registry (resolveAgent)

data Command
  = Init (Maybe Text) (Maybe Text)
  | FilesClaim Text [FilePath] Bool
  | FilesUnclaim Text [FilePath]
  | FilesStatus
  | CommitCmd Text Text
  | ReserveCmd Text Text (Maybe Int) Int Bool
  | ReleaseCmd Text Text
  | ReservationsCmd
  | List
  | Cleanup Text
  | Tee Text
  deriving (Show)

commandParser :: Parser Command
commandParser = hsubparser
  ( command "init" (info initParser (progDesc "Initialize an agent"))
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
  <$> optional (argument (T.pack <$> str) (metavar "HASH"))
  <*> optional (option (T.pack <$> str)
      ( long "name"
      <> metavar "NAME"
      <> help "Human-readable name for this agent (can be used instead of hash)" ))

filesParser :: Parser Command
filesParser = hsubparser
  ( command "claim" (info filesClaimParser (progDesc "Claim files"))
  <> command "unclaim" (info filesUnclaimParser (progDesc "Unclaim files"))
  <> command "status" (info filesStatusParser (progDesc "Show file status"))
  )

filesClaimParser :: Parser Command
filesClaimParser = FilesClaim
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")
  <*> some (argument str (metavar "PATH..."))
  <*> switch (long "shared" <> help "Allow co-claiming with another agent")

filesUnclaimParser :: Parser Command
filesUnclaimParser = FilesUnclaim
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")
  <*> some (argument str (metavar "PATH..."))

filesStatusParser :: Parser Command
filesStatusParser = pure FilesStatus

commitParser :: Parser Command
commitParser = CommitCmd
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")
  <*> option (T.pack <$> str)
      ( short 'm'
      <> metavar "MESSAGE"
      <> help "Commit message" )

reserveParser :: Parser Command
reserveParser = ReserveCmd
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")
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
  <*> switch (long "renew" <> help "Atomically release before re-reserving (avoids race condition)")

releaseParser :: Parser Command
releaseParser = ReleaseCmd
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")
  <*> argument (T.pack <$> str) (metavar "RESOURCE")

reservationsParser :: Parser Command
reservationsParser = pure ReservationsCmd

listParser :: Parser Command
listParser = pure List

cleanupParser :: Parser Command
cleanupParser = Cleanup
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")

teeParser :: Parser Command
teeParser = Tee
  <$> argument (T.pack <$> str) (metavar "HASH|NAME")

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

-- | Resolve name-or-hash for all commands except Init (which creates the agent).
runCommand :: Command -> IO ()
runCommand (Init mbHash mbName)              = cmdInit mbHash mbName
runCommand (FilesClaim ref paths shared)     = resolveAgent ref >>= \h -> cmdFilesClaim h paths shared
runCommand (FilesUnclaim ref paths)          = resolveAgent ref >>= \h -> cmdFilesUnclaim h paths
runCommand FilesStatus                       = cmdFilesStatus
runCommand (CommitCmd ref msg)               = resolveAgent ref >>= \h -> cmdCommit h msg
runCommand (ReserveCmd ref res ttl to rel)    = resolveAgent ref >>= \h -> cmdReserve h res ttl to rel
runCommand (ReleaseCmd ref res)              = resolveAgent ref >>= \h -> cmdRelease h res
runCommand ReservationsCmd                   = cmdReservations
runCommand List                              = cmdList
runCommand (Cleanup ref)                     = resolveAgent ref >>= \h -> cmdCleanup h
runCommand (Tee ref)                         = resolveAgent ref >>= \h -> cmdTee h
