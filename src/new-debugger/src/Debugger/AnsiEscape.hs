{-# LANGUAGE TupleSections#-}
{-# LANGUAGE OverloadedStrings #-}
-- | Parse text containing ANSI escape codes
--
-- The parser only handles colors and the \"bold\" property at the moment.

-- Copied from https://github.com/emilaxelsson/trackit/blob/bf18534d7846c0bf5b0770325739e539d2288645/src/ParseANSI.hs
-- Copyright Emil Axelsson
module Debugger.AnsiEscape where

-- Reference: <http://ascii-table.com/ansi-escape-sequences.php>

import Data.Monoid (Endo (..))
import Data.Text (Text)
import qualified Data.Text as Text

import Graphics.Vty.Attributes

readMay :: Read a => Text -> Maybe a
readMay t = case reads $ Text.unpack t of
  [(a, "")] -> Just a
  _ -> Nothing

onHead :: (a -> a) -> [a] -> [a]
onHead _ [] = []
onHead f (a:as) = f a : as

esc :: Text
esc = "\ESC["

-- | Parse a text that has been preceded by an 'esc' sequence
--
-- The result contains the control codes and the rest of the text.
parseEsc :: Text -> Maybe ([Int], Text)
parseEsc t = case Text.uncons rest of
    Just ('m', rest') -> (, rest') <$> parseCodes codes
    _ -> Nothing
  where
    codes = Text.takeWhile (/= 'm') t
    rest = Text.dropWhile (/= 'm') t

    parseCodes :: Text -> Maybe [Int]
    parseCodes = mapM readMay . filter (not . Text.null) . Text.splitOn ";"

-- | Mapping from control code to 'Attr'
-- (reference: <http://ascii-table.com/ansi-escape-sequences.php>)
codeMap :: [(Int, Endo Attr)]
codeMap =
  [ (1,  Endo (`withStyle`     bold))
  , (30, Endo (`withForeColor` black))
  , (31, Endo (`withForeColor` red))
  , (32, Endo (`withForeColor` green))
  , (33, Endo (`withForeColor` yellow))
  , (34, Endo (`withForeColor` blue))
  , (35, Endo (`withForeColor` magenta))
  , (36, Endo (`withForeColor` cyan))
  , (37, Endo (`withForeColor` white))
  , (90, Endo (`withForeColor` brightBlack))
  , (91, Endo (`withForeColor` brightRed))
  , (92, Endo (`withForeColor` brightGreen))
  , (93, Endo (`withForeColor` brightYellow))
  , (94, Endo (`withForeColor` brightBlue))
  , (95, Endo (`withForeColor` brightMagenta))
  , (96, Endo (`withForeColor` brightCyan))
  , (97, Endo (`withForeColor` brightWhite))
  ]

-- | Lookup a code in 'codeMap' and return @`Endo` `id`@ if it's not present
lookCode :: Int -> Endo Attr
lookCode c = maybe (Endo id) id $ lookup c codeMap

-- | A text segment paired with some attribute
data Segment = Segment
  { attribute :: Attr
  , content :: Text
  } deriving (Eq, Show)

-- | Parse a segment that has been preceded by an 'esc' sequence and does not
-- have any other occurrences of 'esc' inside
parseSegment :: Text -> Segment
parseSegment s
  | Just (cs, rest) <- parseEsc s = Segment (mkAttr cs) rest
  | otherwise = Segment defAttr s
  where
    mkAttr cs = foldMap lookCode cs `appEndo` defAttr

-- | Parse a text containing ANSI control codes
parseANSI :: Text -> [Segment]
parseANSI = map parseSegment . onHead fixHead . Text.splitOn esc
  where
    -- Ensure that the text starts with an escape code
    fixHead :: Text -> Text
    fixHead h = case Text.breakOn esc h of
      ("", _) -> h -- Already starts with `esc`
      (h1, _empty) -> Text.cons 'm' h1
        -- No `esc` in the string (because `splitOn` makes sure that the
        -- separator is either first in the segment or absent)
