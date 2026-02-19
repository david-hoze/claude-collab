module ClaudeCollab.Git
  ( gitStatus
  , gitAdd
  , gitCommit
  , GitFileStatus(..)
  , parseGitStatus
  ) where

import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

data GitFileStatus = GitFileStatus
  { gfsStatus :: Text   -- e.g. "M", "A", "??", "D"
  , gfsPath   :: FilePath
  } deriving (Show, Eq)

-- | Run git status --porcelain and parse the output.
gitStatus :: IO (Either Text [GitFileStatus])
gitStatus = do
  (code, out, err) <- readProcessWithExitCode "git" ["status", "--porcelain"] ""
  case code of
    ExitSuccess   -> return $ Right (parseGitStatus out)
    ExitFailure _ -> return $ Left (T.pack err)

-- | Parse git status --porcelain output.
parseGitStatus :: String -> [GitFileStatus]
parseGitStatus = map parseLine . filter (not . null) . lines
  where
    parseLine line =
      let status = T.strip $ T.pack $ take 2 line
          path   = dropWhile isSpace $ drop 2 line
      in GitFileStatus status path

-- | Run git add on specific files.
gitAdd :: [FilePath] -> IO (Either Text ())
gitAdd [] = return (Right ())
gitAdd files = do
  (code, _, err) <- readProcessWithExitCode "git" ("add" : files) ""
  case code of
    ExitSuccess   -> return (Right ())
    ExitFailure _ -> return (Left (T.pack err))

-- | Run git commit with the given message. Returns the short hash on success.
gitCommit :: String -> IO (Either Text Text)
gitCommit msg = do
  (code, out, err) <- readProcessWithExitCode "git" ["commit", "-m", msg] ""
  case code of
    ExitSuccess   -> return $ Right (extractHash out)
    ExitFailure _ -> return $ Left (T.pack err)
  where
    -- Try to extract the short hash from git commit output like "[branch abc1234] message"
    extractHash s =
      let ws = words s
      in case ws of
        (_:hashWord:_) -> T.pack $ filter (/= ']') hashWord
        _              -> T.pack (take 40 s)
