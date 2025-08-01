{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{- |
   Module      : Text.Pandoc.Readers.Org.Inlines
   Copyright   : Copyright (C) 2014-2024 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <albert+pandoc@tarleb.com>

Parsers for Org-mode inline elements.
-}
module Text.Pandoc.Readers.Org.Inlines
  ( inline
  , inlines
  , addToNotesTable
  , linkTarget
  ) where

import Text.Pandoc.Readers.Org.BlockStarts (endOfBlock, noteMarker)
import Text.Pandoc.Readers.Org.ParserState
import Text.Pandoc.Readers.Org.Parsing
import Text.Pandoc.Readers.Org.Shared (cleanLinkText, isImageFilename,
                                       originalLang, translateLang, exportsCode)

import Text.Pandoc.Builder (Inlines)
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Class.PandocMonad (PandocMonad)
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Readers.LaTeX (inlineCommand, rawLaTeXInline)
import Text.TeXMath (DisplayType (..), readTeX, writePandoc)
import Text.Pandoc.Sources (ToSources(..))
import qualified Text.TeXMath.Readers.MathML.EntityMap as MathMLEntityMap
import Safe (lastMay)
import Control.Monad (guard, mplus, mzero, unless, when, void)
import Control.Monad.Trans (lift)
import Data.Char (isAlphaNum, isSpace)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T

--
-- Functions acting on the parser state
--
pushToInlineCharStack :: PandocMonad m => Char -> OrgParser m ()
pushToInlineCharStack c = updateState $ \s ->
  s{ orgStateEmphasisCharStack = c:orgStateEmphasisCharStack s }

popInlineCharStack :: PandocMonad m => OrgParser m ()
popInlineCharStack = updateState $ \s ->
  s{ orgStateEmphasisCharStack = drop 1 . orgStateEmphasisCharStack $ s }

surroundingEmphasisChar :: PandocMonad m => OrgParser m [Char]
surroundingEmphasisChar =
  take 1 . drop 1 . orgStateEmphasisCharStack <$> getState

startEmphasisNewlinesCounting :: PandocMonad m => Int -> OrgParser m ()
startEmphasisNewlinesCounting maxNewlines = updateState $ \s ->
  s{ orgStateEmphasisNewlines = Just maxNewlines }

decEmphasisNewlinesCount :: PandocMonad m => OrgParser m ()
decEmphasisNewlinesCount = updateState $ \s ->
  s{ orgStateEmphasisNewlines = (\n -> n - 1) <$> orgStateEmphasisNewlines s }

newlinesCountWithinLimits :: PandocMonad m => OrgParser m Bool
newlinesCountWithinLimits = do
  st <- getState
  return $ ((< 0) <$> orgStateEmphasisNewlines st) /= Just True

resetEmphasisNewlines :: PandocMonad m => OrgParser m ()
resetEmphasisNewlines = updateState $ \s ->
  s{ orgStateEmphasisNewlines = Nothing }

addToNotesTable :: PandocMonad m => OrgNoteRecord -> OrgParser m ()
addToNotesTable note = do
  oldnotes <- orgStateNotes' <$> getState
  updateState $ \s -> s{ orgStateNotes' = note:oldnotes }

-- | Parse a single Org-mode inline element
inline :: PandocMonad m => OrgParser m (F Inlines)
inline =
  choice [ whitespace
         , linebreak
         , cite
         , footnote
         , linkOrImage
         , anchor
         , inlineCodeBlock
         , str
         , endline
         , emphasizedText
         , code
         , math
         , displayMath
         , verbatim
         , subscript
         , superscript
         , inlineLaTeX
         , exportSnippet
         , macro
         , smart
         , symbol
         ] <* (guard =<< newlinesCountWithinLimits)
  <?> "inline"

-- | Read the rest of the input as inlines.
inlines :: PandocMonad m => OrgParser m (F Inlines)
inlines = trimInlinesF . mconcat <$> many1 inline

-- treat these as potentially non-text when parsing inline:
specialChars :: [Char]
specialChars = "\"$'()*+-,./:;<=>@[\\]^_{|}~"


whitespace :: PandocMonad m => OrgParser m (F Inlines)
whitespace = pure B.space <$ skipMany1 spaceChar
                          <* updateLastPreCharPos
                          <* updateLastForbiddenCharPos
             <?> "whitespace"

linebreak :: PandocMonad m => OrgParser m (F Inlines)
linebreak = try $ pure B.linebreak <$ string "\\\\" <* skipSpaces <* newline

str :: PandocMonad m => OrgParser m (F Inlines)
str = return . B.str <$>
      ( many1Char (noneOf $ specialChars ++ "\n\r ") >>= updatePositions' )
      <* updateLastStrPos
  where
    updatePositions' str' = str' <$
      maybe mzero (updatePositions . snd) (T.unsnoc str')

-- | An endline character that can be treated as a space, not a structural
-- break.  This should reflect the values of the Emacs variable
-- @org-element-pagaraph-separate@.
endline :: PandocMonad m => OrgParser m (F Inlines)
endline = try $ do
  newline
  notFollowedBy' endOfBlock
  decEmphasisNewlinesCount
  guard =<< newlinesCountWithinLimits
  updateLastPreCharPos
  useHardBreaks <- exportPreserveBreaks . orgStateExportSettings <$> getState
  returnF (if useHardBreaks then B.linebreak else B.softbreak)


--
-- Citations
--

-- We first try to parse official org-cite citations, then fall
-- back to org-ref citations (which are still in wide use).

-- | A citation in org-cite style
orgCite :: PandocMonad m => OrgParser m (F [Citation])
orgCite = try $ do
  string "[cite"
  (sty, _variants) <- citeStyle
  char ':'
  spnl
  globalPref <- option mempty (try (citePrefix <* char ';'))
  items <- citeItems
  globalSuff <- option mempty (try (char ';' *> citeSuffix))
  spnl
  char ']'
  return $ adjustCiteStyle sty .
           addPrefixToFirstItem globalPref .
           addSuffixToLastItem globalSuff $ items

adjustCiteStyle :: CiteStyle -> (F [Citation]) -> (F [Citation])
adjustCiteStyle sty cs = do
  cs' <- cs
  case cs' of
    [] -> return []
    (d:ds)  -- TODO needs refinement
      -> case sty of
         TextStyle -> return $ d{ citationMode = AuthorInText
                                , citationSuffix = dropWhile (== Space)
                                    (citationSuffix d)} : ds
         NoAuthorStyle -> return $ d{ citationMode = SuppressAuthor } : ds
         _ -> return (d:ds)

addPrefixToFirstItem :: (F Inlines) -> (F [Citation]) -> (F [Citation])
addPrefixToFirstItem aff cs = do
  cs' <- cs
  aff' <- aff
  case cs' of
    [] -> return []
    (d:ds) -> return (d{ citationPrefix =
                          B.toList aff' <> citationPrefix d }:ds)

addSuffixToLastItem :: (F Inlines) -> (F [Citation]) -> (F [Citation])
addSuffixToLastItem aff cs = do
  cs' <- cs
  aff' <- aff
  case lastMay cs' of
    Nothing -> return cs'
    Just d  ->
      return (init cs' ++ [d{ citationSuffix =
                                citationSuffix d <> B.toList aff' }])

citeItems :: PandocMonad m => OrgParser m (F [Citation])
citeItems = sequence <$> sepBy1' citeItem (char ';' <* void (many spaceChar))

citeItem :: PandocMonad m => OrgParser m (F Citation)
citeItem = try $ do
  pref <- citePrefix
  itemKey <- orgCiteKey
  suff <- citeSuffix
  return $ do
    pre' <- pref
    suf' <- suff
    return Citation
      { citationId      = itemKey
      , citationPrefix  = B.toList pre'
      , citationSuffix  = B.toList suf'
      , citationMode    = NormalCitation
      , citationNoteNum = 0
      , citationHash    = 0
      }

orgCiteKey :: PandocMonad m => OrgParser m Text
orgCiteKey = do
  char '@'
  T.pack <$> many1 (satisfy orgCiteKeyChar)

orgCiteKeyChar :: Char -> Bool
orgCiteKeyChar c =
  isAlphaNum c || c `elem` ['.',':','?','!','`','\'','/','*','@','+','|',
                            '(',')','{','}','<','>','&','_','^','$','#',
                            '%','~','-']

rawAffix :: PandocMonad m => Bool -> OrgParser m Text
rawAffix isPrefix = snd <$> withRaw
  (many
   (affixChar
     <|>
     try (void (char '[' >> rawAffix isPrefix >> char ']'))))
 where
   affixChar = void $ satisfy $ \c ->
     not (c == '^' || c == ';' || c == '[' || c == ']') &&
     (not isPrefix || c /= '@')

citePrefix :: PandocMonad m => OrgParser m (F Inlines)
citePrefix =
  rawAffix True >>= parseFromString (trimInlinesF . mconcat <$> many inline)

citeSuffix :: PandocMonad m => OrgParser m (F Inlines)
citeSuffix =
  rawAffix False >>= parseFromString (mconcat <$> many inline)

citeStyle :: PandocMonad m => OrgParser m (CiteStyle, [CiteVariant])
citeStyle = do
  sty <- option NilStyle $ try $ char '/' *> orgCiteStyle
  variants <- option [] $ try $ char '/' *> orgCiteVariants
  return (sty, variants)

orgCiteStyle :: PandocMonad m => OrgParser m CiteStyle
orgCiteStyle = try $ do
  s <- many1 letter
  case s of
    "author" -> pure AuthorStyle
    "a" -> pure AuthorStyle
    "noauthor" -> pure NoAuthorStyle
    "na" -> pure NoAuthorStyle
    "nocite" -> pure NociteStyle
    "n" -> pure NociteStyle
    "text" -> pure TextStyle
    "t" -> pure TextStyle
    "note" -> pure NoteStyle
    "ft" -> pure NoteStyle
    "numeric" -> pure NumericStyle
    "nb" -> pure NumericStyle
    "nil" -> pure NilStyle
    _ -> fail $ "Unknown org cite style " <> show s

orgCiteVariants :: PandocMonad m => OrgParser m [CiteVariant]
orgCiteVariants =
  (sepBy1' fullnameVariant (char '-')) <|> (many1 onecharVariant)
 where
  fullnameVariant = choice $ map try
     [ Bare <$ string "bare"
     , Caps <$ string "caps"
     , Full <$ string "full"
     ]
  onecharVariant = choice
     [ Bare <$ char 'b'
     , Caps <$ char 'c'
     , Full <$ char 'f'
     ]

data CiteStyle =
    AuthorStyle
  | NoAuthorStyle
  | LocatorsStyle
  | NociteStyle
  | TextStyle
  | NoteStyle
  | NumericStyle
  | NilStyle
  deriving Show

data CiteVariant =
    Caps
  | Bare
  | Full
  deriving Show


spnl :: PandocMonad m => OrgParser m ()
spnl =
  skipSpaces *> optional (newline *> notFollowedBy blankline *> skipSpaces)

cite :: PandocMonad m => OrgParser m (F Inlines)
cite = do
  guardEnabled Ext_citations
  (cs, raw) <- withRaw $ try $ choice
               [ orgCite
               , orgRefCite
               ]
  return $ flip B.cite (B.text raw) <$> cs

-- org-ref

orgRefCite :: PandocMonad m => OrgParser m (F [Citation])
orgRefCite = try $ choice
  [ normalOrgRefCite
  , fmap (:[]) <$> linkLikeOrgRefCite
  ]

normalOrgRefCite :: PandocMonad m => OrgParser m (F [Citation])
normalOrgRefCite = try $ do
  mode <- orgRefCiteMode
  firstCitation <- orgRefCiteList mode
  moreCitations <- many (try $ char ',' *> orgRefCiteList mode)
  return . sequence $ firstCitation : moreCitations
 where
  -- A list of org-ref style citation keys, parsed as citation of the given
  -- citation mode.
  orgRefCiteList :: PandocMonad m => CitationMode -> OrgParser m (F Citation)
  orgRefCiteList citeMode = try $ do
    key <- orgRefCiteKey
    returnF Citation
     { citationId      = key
     , citationPrefix  = mempty
     , citationSuffix  = mempty
     , citationMode    = citeMode
     , citationNoteNum = 0
     , citationHash    = 0
     }

-- | Read a link-like org-ref style citation.  The citation includes pre and
-- post text.  However, multiple citations are not possible due to limitations
-- in the syntax.
linkLikeOrgRefCite :: PandocMonad m => OrgParser m (F Citation)
linkLikeOrgRefCite = try $ do
  _    <- string "[["
  mode <- orgRefCiteMode
  key  <- orgRefCiteKey
  _    <- string "]["
  pre  <- trimInlinesF . mconcat <$> manyTill inline (try $ string "::")
  spc  <- option False (True <$ spaceChar)
  suf  <- trimInlinesF . mconcat <$> manyTill inline (try $ string "]]")
  return $ do
    pre' <- pre
    suf' <- suf
    return Citation
      { citationId      = key
      , citationPrefix  = B.toList pre'
      , citationSuffix  = B.toList (if spc then B.space <> suf' else suf')
      , citationMode    = mode
      , citationNoteNum = 0
      , citationHash    = 0
      }

-- | Read a citation key.  The characters allowed in citation keys are taken
-- from the `org-ref-cite-re` variable in `org-ref.el`.
orgRefCiteKey :: PandocMonad m => OrgParser m Text
orgRefCiteKey =
  let citeKeySpecialChars = "-_:\\./" :: String
      isCiteKeySpecialChar c = c `elem` citeKeySpecialChars
      isCiteKeyChar c = isAlphaNum c || isCiteKeySpecialChar c
      endOfCitation = try $ do
        many $ satisfy isCiteKeySpecialChar
        satisfy $ not . isCiteKeyChar
  in try $ do
        optional (char '&') -- this is used in org-ref v3
        satisfy isCiteKeyChar `many1TillChar` lookAhead endOfCitation

-- | Supported citation types.  Only a small subset of org-ref types is
-- supported for now.  TODO: rewrite this, use LaTeX reader as template.
orgRefCiteMode :: PandocMonad m => OrgParser m CitationMode
orgRefCiteMode =
  choice $ map (\(s, mode) -> mode <$ try (string s <* char ':'))
    [ ("cite", AuthorInText)
    , ("citep", NormalCitation)
    , ("citep*", NormalCitation)
    , ("citet", AuthorInText)
    , ("citet*", AuthorInText)
    , ("citeyear", SuppressAuthor)
    ]

footnote :: PandocMonad m => OrgParser m (F Inlines)
footnote = try $ do
  note <- inlineNote <|> referencedNote
  withNote <- getExportSetting exportWithFootnotes
  return $ if withNote then note else mempty

inlineNote :: PandocMonad m => OrgParser m (F Inlines)
inlineNote = try $ do
  string "[fn:"
  ref <- manyChar alphaNum
  char ':'
  note <- fmap B.para . trimInlinesF . mconcat <$> many1Till inline (char ']')
  unless (T.null ref) $
       addToNotesTable ("fn:" <> ref, note)
  return $ B.note <$> note

referencedNote :: PandocMonad m => OrgParser m (F Inlines)
referencedNote = try $ do
  ref <- noteMarker
  return $ do
    notes <- asksF orgStateNotes'
    case lookup ref notes of
      Nothing   -> return . B.str $ "[" <> ref <> "]"
      Just contents  -> do
        st <- askF
        let contents' = runF contents st{ orgStateNotes' = [] }
        return $ B.note contents'

linkOrImage :: PandocMonad m => OrgParser m (F Inlines)
linkOrImage = explicitOrImageLink
              <|> selflinkOrImage
              <|> angleLink
              <|> plainLink
              <?> "link or image"

explicitOrImageLink :: PandocMonad m => OrgParser m (F Inlines)
explicitOrImageLink = try $ do
  char '['
  srcF   <- applyCustomLinkFormat =<< possiblyEmptyLinkTarget
  descr  <- enclosedRaw (char '[') (char ']')
  titleF <- parseFromString (mconcat <$> many inline) descr
  char ']'
  return $ do
    src <- srcF
    title <- titleF
    case cleanLinkText descr of
      Just imgSrc | isImageFilename imgSrc ->
        return . B.link src "" $ B.image imgSrc mempty mempty
      _ ->
        linkToInlinesF src title

selflinkOrImage :: PandocMonad m => OrgParser m (F Inlines)
selflinkOrImage = try $ do
  target <- char '[' *> linkTarget <* char ']'
  case cleanLinkText target of
    Nothing        -> case T.uncons target of
                        Just ('#', _) -> returnF $ B.link target "" (B.str target)
                        _             -> return $ internalLink target (B.str target)
    Just nonDocTgt -> if isImageFilename nonDocTgt
                      then returnF $ B.image nonDocTgt "" ""
                      else returnF $ B.link nonDocTgt "" (B.str target)

plainLink :: PandocMonad m => OrgParser m (F Inlines)
plainLink = try $ do
  (orig, src) <- uri
  returnF $ B.link src "" (B.str orig)

angleLink :: PandocMonad m => OrgParser m (F Inlines)
angleLink = try $ do
  char '<'
  link <- plainLink
  char '>'
  return link

linkTarget :: PandocMonad m => OrgParser m Text
linkTarget = T.pack <$> enclosedByPair1 '[' ']' (noneOf "\n\r[]")

possiblyEmptyLinkTarget :: PandocMonad m => OrgParser m Text
possiblyEmptyLinkTarget = try linkTarget <|> ("" <$ string "[]")

applyCustomLinkFormat :: Text -> OrgParser m (F Text)
applyCustomLinkFormat link = do
  let (linkType, rest) = T.break (== ':') link
  return $ do
    formatter <- M.lookup linkType <$> asksF orgStateLinkFormatters
    return $ maybe link ($ T.drop 1 rest) formatter

-- | Take a link and return a function which produces new inlines when given
-- description inlines.
linkToInlinesF :: Text -> Inlines -> F Inlines
linkToInlinesF linkStr =
  case T.uncons linkStr of
    Nothing       -> pure . B.link mempty ""       -- wiki link (empty by convention)
    Just ('#', _) -> pure . B.link linkStr ""      -- document-local fraction
    _             -> case cleanLinkText linkStr of
      Just extTgt -> return . B.link extTgt ""
      Nothing     -> internalLink linkStr  -- other internal link

internalLink :: Text -> Inlines -> F Inlines
internalLink link title = do
  ids <- asksF orgStateAnchorIds
  if link `elem` ids
    then return $ B.link ("#" <> link) "" title
    else let attr' = ("", ["spurious-link"] , [("target", link)])
         in return $ B.spanWith attr' (B.emph title)

-- | Parse an anchor like @<<anchor-id>>@ and return an empty span with
-- @anchor-id@ set as id.  Legal anchors in org-mode are defined through
-- @org-target-regexp@, which is fairly liberal.  Since no link is created if
-- @anchor-id@ contains spaces, we are more restrictive in what is accepted as
-- an anchor.
anchor :: PandocMonad m => OrgParser m (F Inlines)
anchor =  do
  anchorId <- orgAnchor
  returnF $ B.spanWith (solidify anchorId, [], []) mempty

-- | Replace every char but [a-zA-Z0-9_.-:] with a hyphen '-'.  This mirrors
-- the org function @org-export-solidify-link-text@.
solidify :: Text -> Text
solidify = T.map replaceSpecialChar
 where replaceSpecialChar c
           | isAlphaNum c    = c
           | c `elem` ("_.-:" :: String) = c
           | otherwise       = '-'

-- | Parses an inline code block and marks it as an babel block.
inlineCodeBlock :: PandocMonad m => OrgParser m (F Inlines)
inlineCodeBlock = try $ do
  string "src_"
  lang <- many1Char orgArgWordChar
  opts <- option [] $ enclosedByPair '[' ']' inlineBlockOption
  inlineCode <- T.pack <$> enclosedByPair1 '{' '}' (noneOf "\n\r")
  let attrClasses = [translateLang lang]
  let attrKeyVal  = originalLang lang <> opts
  let codeInlineBlck = B.codeWith ("", attrClasses, attrKeyVal) inlineCode
  returnF $ if exportsCode opts then codeInlineBlck else mempty
 where
   inlineBlockOption :: PandocMonad m => OrgParser m (Text, Text)
   inlineBlockOption = try $ do
     argKey <- orgArgKey
     paramValue <- option "yes" orgInlineParamValue
     return (argKey, paramValue)

   orgInlineParamValue :: PandocMonad m => OrgParser m Text
   orgInlineParamValue = try $
     skipSpaces
       *> notFollowedBy (char ':')
       *> many1Char (noneOf "\t\n\r ]")
       <* skipSpaces


emphasizedText :: PandocMonad m => OrgParser m (F Inlines)
emphasizedText = do
  state <- getState
  guard . exportEmphasizedText . orgStateExportSettings $ state
  try $ choice
    [ emph
    , strong
    , strikeout
    , underline
    ]

enclosedByPair :: PandocMonad m
               => Char          -- ^ opening char
               -> Char          -- ^ closing char
               -> OrgParser m a   -- ^ parser
               -> OrgParser m [a]
enclosedByPair s e p = char s *> manyTill p (char e)

enclosedByPair1 :: PandocMonad m
               => Char          -- ^ opening char
               -> Char          -- ^ closing char
               -> OrgParser m a   -- ^ parser
               -> OrgParser m [a]
enclosedByPair1 s e p = char s *> many1Till p (char e)

emph      :: PandocMonad m => OrgParser m (F Inlines)
emph      = fmap B.emph         <$> emphasisBetween '/'

strong    :: PandocMonad m => OrgParser m (F Inlines)
strong    = fmap B.strong       <$> emphasisBetween '*'

strikeout :: PandocMonad m => OrgParser m (F Inlines)
strikeout = fmap B.strikeout    <$> emphasisBetween '+'

underline :: PandocMonad m => OrgParser m (F Inlines)
underline = fmap B.underline    <$> emphasisBetween '_'

verbatim  :: PandocMonad m => OrgParser m (F Inlines)
verbatim  = return . B.codeWith ("", ["verbatim"], []) <$> verbatimBetween '='

code      :: PandocMonad m => OrgParser m (F Inlines)
code      = return . B.code     <$> verbatimBetween '~'

subscript   :: PandocMonad m => OrgParser m (F Inlines)
subscript   = fmap B.subscript   <$> try (char '_' *> subOrSuperExpr)

superscript :: PandocMonad m => OrgParser m (F Inlines)
superscript = fmap B.superscript <$> try (char '^' *> subOrSuperExpr)

math      :: PandocMonad m => OrgParser m (F Inlines)
math      = return . B.math      <$> choice [ math1CharBetween '$'
                                            , mathTextBetween '$'
                                            , rawMathBetween "\\(" "\\)"
                                            ]

displayMath :: PandocMonad m => OrgParser m (F Inlines)
displayMath = return . B.displayMath <$> choice [ rawMathBetween "\\[" "\\]"
                                                , rawMathBetween "$$"  "$$"
                                                ]

updatePositions :: PandocMonad m
                => Char
                -> OrgParser m Char
updatePositions c = do
  st <- getState
  let emphasisPreChars = orgStateEmphasisPreChars st
  when (c `elem` emphasisPreChars) updateLastPreCharPos
  when (c `elem` emphasisForbiddenBorderChars) updateLastForbiddenCharPos
  return c

symbol :: PandocMonad m => OrgParser m (F Inlines)
symbol = return . B.str . T.singleton <$> (oneOf specialChars >>= updatePositions)

emphasisBetween :: PandocMonad m
                => Char
                -> OrgParser m (F Inlines)
emphasisBetween c = try $ do
  startEmphasisNewlinesCounting emphasisAllowedNewlines
  res <- enclosedInlines (emphasisStart c) (emphasisEnd c)
  isTopLevelEmphasis <- null . orgStateEmphasisCharStack <$> getState
  when isTopLevelEmphasis
       resetEmphasisNewlines
  return res

verbatimBetween :: PandocMonad m
                => Char
                -> OrgParser m Text
verbatimBetween c = newlinesToSpaces <$>
  try (emphasisStart c *> many1TillNOrLessNewlines 1 verbatimChar (emphasisEnd c))
 where
   verbatimChar = noneOf "\n\r" >>= updatePositions
   newlinesToSpaces = T.map (\d -> if d == '\n' then ' ' else d)

-- | Parses a raw string delimited by @c@ using Org's math rules
mathTextBetween :: PandocMonad m
                  => Char
                  -> OrgParser m Text
mathTextBetween c = try $ do
  mathStart c
  body <- many1TillNOrLessNewlines mathAllowedNewlines
                                   (noneOf (c:"\n\r"))
                                   (lookAhead $ mathEnd c)
  final <- mathEnd c
  return $ T.snoc body final

-- | Parse a single character between @c@ using math rules
math1CharBetween :: PandocMonad m
                 => Char
                -> OrgParser m Text
math1CharBetween c = try $ do
  char c
  res <- noneOf $ c:mathForbiddenBorderChars
  char c
  eof <|> () <$ lookAhead (oneOf mathPostChars)
  return $ T.singleton res

rawMathBetween :: PandocMonad m
               => Text
               -> Text
               -> OrgParser m Text
rawMathBetween s e = try $ textStr s *> manyTillChar anyChar (try $ textStr e)

-- | Parses the start (opening character) of emphasis
emphasisStart :: PandocMonad m => Char -> OrgParser m Char
emphasisStart c = try $ do
  guard =<< afterEmphasisPreChar
  char c
  lookAhead (noneOf emphasisForbiddenBorderChars)
  pushToInlineCharStack c
  -- nested inlines are allowed, so mark this position as one which might be
  -- followed by another inline.
  updateLastPreCharPos
  return c

-- | Parses the closing character of emphasis
emphasisEnd :: PandocMonad m => Char -> OrgParser m Char
emphasisEnd c = try $ do
  guard =<< notAfterForbiddenBorderChar
  char c
  eof <|> () <$ lookAhead acceptablePostChars
  updateLastStrPos
  popInlineCharStack
  return c
 where
  acceptablePostChars = do
    emphasisPostChars <- orgStateEmphasisPostChars <$> getState
    surroundingEmphasisChar >>= \x -> oneOf (x ++ emphasisPostChars)

mathStart :: PandocMonad m => Char -> OrgParser m Char
mathStart c = try $
  char c <* notFollowedBy' (oneOf (c:mathForbiddenBorderChars))

mathEnd :: PandocMonad m => Char -> OrgParser m Char
mathEnd c = try $ do
  res <- noneOf (c:mathForbiddenBorderChars)
  char c
  eof <|> () <$ lookAhead (oneOf mathPostChars)
  return res


enclosedInlines :: (PandocMonad m, Show b) => OrgParser m a
                -> OrgParser m b
                -> OrgParser m (F Inlines)
enclosedInlines start end = try $
  trimInlinesF . mconcat <$> enclosed start end inline

enclosedRaw :: (PandocMonad m, Show b) => OrgParser m a
            -> OrgParser m b
            -> OrgParser m Text
enclosedRaw start end = try $
  start *> (onSingleLine <|> spanningTwoLines)
 where onSingleLine = try $ many1TillChar (noneOf "\n\r") end
       spanningTwoLines = try $
         anyLine >>= \f -> mappend (f <> " ") <$> onSingleLine

-- | Like many1Till, but parses at most @n+1@ lines.  @p@ must not consume
--   newlines.
many1TillNOrLessNewlines :: PandocMonad m => Int
                         -> OrgParser m Char
                         -> OrgParser m a
                         -> OrgParser m Text
many1TillNOrLessNewlines n p end = try $
  nMoreLines (Just n) mempty >>= oneOrMore
 where
   nMoreLines Nothing  cs = return cs
   nMoreLines (Just 0) cs = try $ (cs ++) <$> finalLine
   nMoreLines k        cs = try $ (final k cs <|> rest k cs)
                                  >>= uncurry nMoreLines
   final _ cs = (\x -> (Nothing,      cs ++ x)) <$> try finalLine
   rest  m cs = (\x -> (minus1 <$> m, cs ++ x ++ "\n")) <$> try (manyTill p newline)
   finalLine = try $ manyTill p end
   minus1 k = k - 1
   oneOrMore cs = T.pack cs <$ guard (not $ null cs)

-- Org allows customization of the way it reads emphasis.  We use the defaults
-- here (see, e.g., the Emacs Lisp variable `org-emphasis-regexp-components`
-- for details).

-- | Chars not allowed at the (inner) border of emphasis
emphasisForbiddenBorderChars :: [Char]
emphasisForbiddenBorderChars = "\t\n\r \x200B"

-- | The maximum number of newlines within
emphasisAllowedNewlines :: Int
emphasisAllowedNewlines = 1

-- LaTeX-style math: see `org-latex-regexps` for details

-- | Chars allowed after an inline ($...$) math statement
mathPostChars :: [Char]
mathPostChars = "\t\n \"'),-.:;?"

-- | Chars not allowed at the (inner) border of math
mathForbiddenBorderChars :: [Char]
mathForbiddenBorderChars = "\t\n\r ,;.$"

-- | Maximum number of newlines in an inline math statement
mathAllowedNewlines :: Int
mathAllowedNewlines = 2

-- | Whether we are right behind a char allowed before emphasis
afterEmphasisPreChar :: PandocMonad m => OrgParser m Bool
afterEmphasisPreChar = do
  pos <- getPosition
  lastPrePos <- orgStateLastPreCharPos <$> getState
  return $ maybe True (== pos) lastPrePos

-- | Whether the parser is right after a forbidden border char
notAfterForbiddenBorderChar :: PandocMonad m => OrgParser m Bool
notAfterForbiddenBorderChar = do
  pos <- getPosition
  lastFBCPos <- orgStateLastForbiddenCharPos <$> getState
  return $ lastFBCPos /= Just pos

-- | Read a sub- or superscript expression
subOrSuperExpr :: PandocMonad m => OrgParser m (F Inlines)
subOrSuperExpr = try $
  simpleSubOrSuperText <|>
  (choice [ charsInBalanced '{' '}' (T.singleton <$> noneOf "\n\r")
          , enclosing ('(', ')') <$> charsInBalanced '(' ')' (T.singleton <$> noneOf "\n\r")
          ] >>= parseFromString (mconcat <$> many inline))
 where enclosing (left, right) s = T.cons left $ T.snoc s right

simpleSubOrSuperText :: PandocMonad m => OrgParser m (F Inlines)
simpleSubOrSuperText = try $ do
  state <- getState
  guard . exportSubSuperscripts . orgStateExportSettings $ state
  return . B.str <$>
    choice [ textStr "*"
           , mappend <$> option "" (T.singleton <$> oneOf "+-")
                     <*> many1Char alphaNum
           ]

inlineLaTeX :: PandocMonad m => OrgParser m (F Inlines)
inlineLaTeX = try $ do
  cmd <- inlineLaTeXCommand
  texOpt <- getExportSetting exportWithLatex
  allowEntities <- getExportSetting exportWithEntities
  ils <- parseAsInlineLaTeX cmd texOpt
  maybe mzero returnF $
    if "\\begin{" `T.isPrefixOf` cmd
       then ils
       else parseAsMathMLSym allowEntities cmd `mplus`
            parseAsMath cmd texOpt `mplus`
            ils
 where
   parseAsInlineLaTeX :: PandocMonad m
                      => Text -> TeXExport -> OrgParser m (Maybe Inlines)
   parseAsInlineLaTeX cs = \case
     TeXExport -> maybeRight <$> runParserT
                  (B.rawInline "latex" . snd <$> withRaw inlineCommand)
                  state "" (toSources cs)
     TeXIgnore -> return (Just mempty)
     TeXVerbatim -> return (Just $ B.text cs)

   parseAsMathMLSym :: Bool -> Text -> Maybe Inlines
   parseAsMathMLSym allowEntities cs = do
     -- drop initial backslash and any trailing "{}"
     let clean = T.dropWhileEnd (`elem` ("{}" :: String)) . T.drop 1
     -- If entities are disabled, then return the string as text, but
     -- only if this *is* a MathML entity.
     case B.str <$> MathMLEntityMap.getUnicode (clean cs) of
       Just _ | not allowEntities -> Just $ B.str cs
       x -> x

   state :: ParserState
   state = def{ stateOptions = def{ readerExtensions =
                    enableExtension Ext_raw_tex (readerExtensions def) } }

   parseAsMath :: Text -> TeXExport -> Maybe Inlines
   parseAsMath cs = \case
     TeXExport -> maybeRight (readTeX cs) >>=
                  fmap B.fromList . writePandoc DisplayInline
     TeXIgnore -> Just mempty
     TeXVerbatim -> Just $ B.str cs

maybeRight :: Either a b -> Maybe b
maybeRight = either (const Nothing) Just

inlineLaTeXCommand :: PandocMonad m => OrgParser m Text
inlineLaTeXCommand = try $ do
  rest <- getInput
  st <- getState
  parsed <- (lift . lift) $ runParserT rawLaTeXInline st "source" rest
  case parsed of
    Right cs -> do
      -- drop any trailing whitespace, those are not part of the command as
      -- far as org mode is concerned.
      let cmdNoSpc = T.dropWhileEnd isSpace cs
      let len = T.length cmdNoSpc
      count len anyChar
      return cmdNoSpc
    _ -> mzero

exportSnippet :: PandocMonad m => OrgParser m (F Inlines)
exportSnippet = try $ do
  string "@@"
  format <- many1TillChar (alphaNum <|> char '-') (char ':')
  snippet <- manyTillChar anyChar (try $ string "@@")
  returnF $ B.rawInline format snippet

macro :: PandocMonad m => OrgParser m (F Inlines)
macro = try $ do
  recursionDepth <- orgStateMacroDepth <$> getState
  guard $ recursionDepth < 15
  string "{{{"
  name <- manyChar alphaNum
  args <- ([] <$ string "}}}")
          <|> char '(' *> argument `sepBy` char ',' <* eoa
  expander <- lookupMacro name <$> getState
  case expander of
    Nothing -> mzero
    Just fn -> do
      updateState $ \s -> s { orgStateMacroDepth = recursionDepth + 1 }
      res <- parseFromString (mconcat <$> many inline) $ fn args
      updateState $ \s -> s { orgStateMacroDepth = recursionDepth }
      return res
 where
  argument = manyChar $ notFollowedBy eoa *> (escapedComma <|> noneOf ",")
  escapedComma = try $ char '\\' *> oneOf ",\\"
  eoa = string ")}}}"

smart :: PandocMonad m => OrgParser m (F Inlines)
smart = choice [doubleQuoted, singleQuoted, orgApostrophe, orgDash, orgEllipses]
  where
    orgDash = do
      guardOrSmartEnabled =<< getExportSetting exportSpecialStrings
      pure <$> dash <* updatePositions '-'
    orgEllipses = do
      guardOrSmartEnabled =<< getExportSetting exportSpecialStrings
      pure <$> ellipses <* updatePositions '.'
    orgApostrophe = do
      guardEnabled Ext_smart
      (char '\'' <|> char '\8217') <* updateLastPreCharPos
                                   <* updateLastForbiddenCharPos
      returnF (B.str "\x2019")

guardOrSmartEnabled :: PandocMonad m => Bool -> OrgParser m ()
guardOrSmartEnabled b = do
  smartExtension <- extensionEnabled Ext_smart <$> getOption readerExtensions
  guard (b || smartExtension)

singleQuoted :: PandocMonad m => OrgParser m (F Inlines)
singleQuoted = try $ do
  guardOrSmartEnabled =<< getExportSetting exportSmartQuotes
  singleQuoteStart
  updatePositions '\''
  withQuoteContext InSingleQuote $
    fmap B.singleQuoted . trimInlinesF . mconcat <$>
      many1Till inline (singleQuoteEnd <* updatePositions '\'')

-- doubleQuoted will handle regular double-quoted sections, as well
-- as dialogues with an open double-quote without a close double-quote
-- in the same paragraph.
doubleQuoted :: PandocMonad m => OrgParser m (F Inlines)
doubleQuoted = try $ do
  guardOrSmartEnabled =<< getExportSetting exportSmartQuotes
  doubleQuoteStart
  updatePositions '"'
  contents <- mconcat <$> many (try $ notFollowedBy doubleQuoteEnd >> inline)
  let doubleQuotedContent = withQuoteContext InDoubleQuote $ do
        doubleQuoteEnd
        updateLastForbiddenCharPos
        return . fmap B.doubleQuoted . trimInlinesF $ contents
  let leftQuoteAndContent = return $ pure (B.str "\8220") <> contents
  doubleQuotedContent <|> leftQuoteAndContent
