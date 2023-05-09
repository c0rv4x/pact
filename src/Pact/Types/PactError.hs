{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      :  Pact.Types.PactError
-- Copyright   :  (C) 2019 Stuart Popejoy, Kadena LLC
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- PactError and related types.
--

module Pact.Types.PactError
  ( StackFrame(..), sfName, sfLoc, sfApp
  , PactError(..)
  , PactErrorType(..)

  , RenderedOutput(..)
  , OutputType(..)
  , roText
  , roInfo
  , roType
  , renderWarn
  , renderFatal
  , _OutputFailure
  , _OutputWarning
  , _OutputTrace
  ) where

import Control.Applicative
import Control.Lens hiding ((.=),DefName, elements)
import Control.Monad
import Control.Monad.Catch
import Data.Aeson hiding (Object)
import Data.Attoparsec.Text as AP
import Data.Default
import Data.Text as T (Text, unpack, pack, init)
import Control.DeepSeq (NFData)

import GHC.Generics

import Test.QuickCheck

import Pact.Types.Lang
import Pact.Types.Orphans ()
import Pact.Types.Pretty

import qualified Pact.JSON.Encode as J

data StackFrame = StackFrame {
      _sfName :: !Text
    , _sfLoc :: !Info
    , _sfApp :: !(Maybe (FunApp,[Text]))
    } deriving (Eq,Generic)
instance NFData StackFrame
instance ToJSON StackFrame where
  toJSON = enableToJSON "Pact.Types.PactError.StackFrame" . toJSON . show
  toEncoding = toEncoding . show
  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance J.Encode StackFrame where
  build = J.text . T.pack . show
  {-# INLINE build #-}

-- | BIG HUGE CAVEAT: Back compat requires maintaining the pre-existing
-- 'ToJSON' instance, so this is ONLY for UX coming out of serialized
-- endpoints like `poll` in Chainweb; "Info" and "FunApp" values will
-- be sketchy. As such this is also permissive on failure.
instance FromJSON StackFrame where
  parseJSON = withText "StackFrame" $ \t -> case parseOnly parseStackFrame t of
    Right sf -> pure sf
    Left e -> pure $ StackFrame ("StackFrame parse failed: " <> pack e) def Nothing


instance Show StackFrame where
    show (StackFrame n i app) = renderInfo i ++ ": " ++ case app of
      Nothing -> unpack n
      Just (_,as) -> "(" ++ unpack n ++ concatMap (\a -> " " ++ unpack (asString a)) as ++ ")"

instance Arbitrary StackFrame where
  arbitrary = StackFrame <$> arbitrary <*> arbitrary <*> arbitrary

-- | Attempt to parse 'Show' instance output. Intentionally avoids parsing app args,
-- cramming all of the text into '_sfName'.
parseStackFrame :: AP.Parser StackFrame
parseStackFrame = do
  i <- parseRenderedInfo
  void $ string ": "
  parseDeets i <|> justName i
  where
    parseDeets i = do
      void $ char '('
      deets <- T.init <$> takeText
      return $ StackFrame deets i $
        Just (FunApp def "" Nothing Defun (funTypes $ FunType [] TyAny) Nothing
             ,[])
    justName i = takeText >>= \n -> return $ StackFrame n i Nothing

_parseStackFrame :: Text -> Either String StackFrame
_parseStackFrame = parseOnly parseStackFrame

makeLenses ''StackFrame


data PactErrorType
  = EvalError
  | ArgsError
  | DbError
  | TxFailure
  | SyntaxError
  | GasError
  | ContinuationError
  deriving (Show,Eq,Generic)
instance NFData PactErrorType
instance ToJSON PactErrorType
instance FromJSON PactErrorType

instance J.Encode PactErrorType where
  build EvalError = J.text "EvalError"
  build ArgsError = J.text "ArgsError"
  build DbError = J.text "DbError"
  build TxFailure = J.text "TxFailure"
  build SyntaxError = J.text "SyntaxError"
  build GasError = J.text "GasError"
  {-# INLINE build #-}

instance Arbitrary PactErrorType where
  arbitrary = elements [ EvalError, ArgsError, DbError, TxFailure, SyntaxError, GasError ]

data PactError = PactError
  { peType :: !PactErrorType
  , peInfo :: !Info
  , peCallStack :: ![StackFrame]
  , peDoc :: !Doc }
  deriving (Eq,Generic)

instance NFData PactError
instance Exception PactError

pactErrorProperties :: JsonProperties PactError
pactErrorProperties o =
  [ "callStack" .= peCallStack o
  , "type" .= peType o
  , "message" .= show (peDoc o)
  , "info" .= renderInfo (peInfo o)
  ]

instance ToJSON PactError where
  toJSON = enableToJSON "Pact.Types.PactError.PactError" . object . pactErrorProperties
  toEncoding = pairs . mconcat . pactErrorProperties
  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance J.Encode PactError where
  build o = J.object
    [ "callStack" J..= J.array (peCallStack o)
    , "type" J..= peType o
    , "message" J..= J.text (T.pack (show (peDoc o)))
    , "info" J..= J.text (T.pack (renderInfo (peInfo o)))
    ]
  {-# INLINE build #-}

-- CAVEAT: this is "UX only" due to issues with Info, StackFrame, and that
-- historically these were ignored here. As such this is a "lenient" parser returning
-- the old values on failure.
instance FromJSON PactError where
  parseJSON = withObject "PactError" $ \o -> do
    typ <- o .: "type"
    doc <- o .: "message"
    inf <- parseInfo <$> o .: "info"
    sf <- parseSFs <$> o .: "callStack"
    pure $ PactError typ inf sf (prettyString doc)
    where
      parseSFs :: [Text] -> [StackFrame]
      parseSFs sfs = case mapM (parseOnly parseStackFrame) sfs of
        Left _e -> []
        Right ss -> ss

instance Arbitrary PactError where
  arbitrary = PactError
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> pure (pretty @String "PRETTY_PRINTER DOC")

-- | Lenient info parser that is empty on error
parseInfo :: Text -> Info
parseInfo t = case parseOnly parseRenderedInfo t of
  Left _e -> def
  Right i -> i

instance Show PactError where
    show (PactError t i _ s) = show i ++ ": Failure: " ++ maybe "" (++ ": ") msg ++ show s
      where msg = case t of
              EvalError -> Nothing
              ArgsError -> Nothing
              TxFailure -> Just "Tx Failed"
              DbError -> Just "Database exception"
              SyntaxError -> Just "Syntax error"
              GasError -> Just "Gas Error"
              ContinuationError -> Just "Continuation Error"

data OutputType =
  OutputFailure |
  OutputWarning |
  OutputTrace
  deriving (Show,Eq,Generic)
instance ToJSON OutputType
instance FromJSON OutputType

instance Arbitrary OutputType where
  arbitrary = elements [OutputFailure, OutputWarning, OutputTrace]

-- | Tool warning/error output.
data RenderedOutput = RenderedOutput
  { _roText :: !Text
  , _roInfo :: !Info
  , _roType :: !OutputType }
  deriving (Eq,Show)

instance Pretty RenderedOutput where
  pretty (RenderedOutput t i f) = pretty (renderInfo i) <> ":" <> pretty (show f) <> ": " <> pretty t

renderedOutputProperties :: JsonProperties RenderedOutput
renderedOutputProperties o =
  [ "text" .= _roText o
  , "type" .= _roType o
  , "info" .= renderInfo (_roInfo o)
  ]

instance ToJSON RenderedOutput where
  toJSON = enableToJSON "Pact.Types.PactError.RenderedOutput" . object . renderedOutputProperties
  toEncoding = pairs . mconcat . renderedOutputProperties
  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance FromJSON RenderedOutput where
  parseJSON = withObject "RenderedOutput" $ \o -> RenderedOutput
      <$> o .: "text"
      <*> (parseInfo <$> o .: "info")
      <*> o .: "type"

instance Arbitrary RenderedOutput where
  arbitrary = RenderedOutput <$> arbitrary <*> arbitrary <*> arbitrary

renderWarn, renderFatal :: Text -> RenderedOutput
renderWarn t = RenderedOutput t def OutputWarning
renderFatal t = RenderedOutput t def OutputFailure


makeLenses ''RenderedOutput
makePrisms ''OutputType
