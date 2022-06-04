{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}



module Pact.Core.Type
 ( PrimType(..)
 , Type(..)
 , RowObject
 , Row(..)
 , InterfaceType(..)
 , ModuleType(..)
 , pattern TyInt
 , pattern TyDecimal
 , pattern TyTime
 , pattern TyBool
 , pattern TyString
 , pattern TyUnit
 , pattern (:~>)
 , tyFunToArgList
 , traverseRowTy
 , typeOfLit
 , BuiltinTC(..)
 , Pred(..)
 , Instance(..)
 , Class(..)
 ) where

import Control.Lens
import Data.List.NonEmpty(NonEmpty)
import qualified Data.Map.Strict as Map

import Pact.Core.Names
import Pact.Core.Literal
import Pact.Core.Pretty(Pretty(..), (<+>))

import qualified Data.List.NonEmpty as NE
import qualified Pact.Core.Pretty as Pretty

data PrimType =
  PrimInt |
  PrimDecimal |
  PrimTime |
  PrimBool |
  PrimString |
  PrimUnit
  deriving (Eq,Ord,Show)

instance Pretty PrimType where
  pretty = \case
    PrimInt -> "integer"
    PrimDecimal -> "decimal"
    PrimTime -> "time"
    PrimBool -> "bool"
    PrimString -> "string"
    PrimUnit -> "unit"

type RowObject n = Map.Map Field (Type n)

data Row n
  = RowTy (RowObject n) (Maybe n)
  | RowVar n
  | EmptyRow
  deriving (Eq, Show, Functor, Foldable, Traversable)

newtype InterfaceType n
  = InterfaceType n
  deriving (Eq, Show)

data ModuleType n
  = ModuleType n [n]
  deriving (Eq, Show)

-- Todo: caps are a bit strange here
-- same with defpacts. Not entirely sure how to type those yet.
-- | Our internal core type language
--   Tables, rows and and interfaces are quite similar,
--    t ::= B
--      |   v
--      |   t -> t
--      |   row
--      |   list<t>
--      |   interface name row
--
--    row  ::= {name:t, row*}
--    row* ::= name:t | ϵ
data Type n
  = TyVar n
  | TyPrim PrimType
  | TyFun (Type n) (Type n)
  | TyRow (Row n)
  -- ^ Row objects
  | TyList (Type n)
  -- ^ List aka [a]
  | TyTable (Row n)
  -- ^ Named tables.
  | TyCap
  -- ^ Capabilities
  -- Atm, until we have a proper constraint system,
  -- caps will simply be enforced @ runtime.
  -- Later on, however, it makes sense to have the set of nominally defined caps in the constraints of a function.
  -- | TyInterface (InterfaceType n)
   -- ^ interfaces, which are nominal
  -- | TyModule (ModuleType n)
  | TCTyCon BuiltinTC (Type n)
  -- ^ module type being the name of the module + implemented interfaces.
  | TyForall (NonEmpty n) (Type n)
  -- ^ Universally quantified types, which have to be part of the type
  -- constructor since system F
  -- If we allow impredicative polymorphism later, it also works.
  deriving (Eq, Show, Functor, Foldable, Traversable)

pattern TyInt :: Type n
pattern TyInt = TyPrim PrimInt

pattern TyDecimal :: Type n
pattern TyDecimal = TyPrim PrimDecimal

pattern TyTime :: Type n
pattern TyTime = TyPrim PrimTime

pattern TyBool :: Type n
pattern TyBool = TyPrim PrimBool

pattern TyString :: Type n
pattern TyString = TyPrim PrimString

pattern TyUnit :: Type n
pattern TyUnit = TyPrim PrimUnit

pattern (:~>) :: Type n -> Type n -> Type n
pattern l :~> r  = TyFun l r

infixr 5 :~>

-- Built in typeclasses
data BuiltinTC
  = Eq
  | Ord
  | Show
  | WithoutField Field
  | Add
  | Num
  deriving (Show, Eq, Ord)

instance Pretty BuiltinTC where
  pretty = \case
    Eq -> "Eq"
    Ord -> "Ord"
    Show -> "Show"
    WithoutField _ -> "<>"
    Add -> "Add"
    Num -> "Num"


-- Note, no superclasses, for now
data Pred tv
  = Pred BuiltinTC (Type tv)
  deriving (Show, Eq)

data Instance tv
  = Instance [Pred tv] (Pred tv)
  deriving Show

data Class tv
  = Class
  { _cName :: BuiltinTC
  , _cSuper :: [BuiltinTC]
  , _cInstances :: [Instance tv]
  } deriving Show


tyFunToArgList :: Type n -> Maybe ([Type n], Type n)
tyFunToArgList (TyFun l r) =
  unFun [l] r
  where
  unFun args (TyFun l' r') = unFun (l':args) r'
  unFun args ret = Just (reverse args, ret)
tyFunToArgList _ = Nothing

traverseRowTy :: Traversal' (Row n) (Type n)
traverseRowTy f = \case
  RowTy tys rv -> RowTy <$> traverse f tys <*> pure rv
  RowVar n -> pure (RowVar n)
  EmptyRow -> pure EmptyRow


instance Plated (Type n) where
  plate f = \case
    TyVar n -> pure (TyVar n)
    TyPrim k -> pure (TyPrim k)
    TyFun l r -> TyFun <$> f l <*> f r
    TyRow rows -> TyRow <$> traverseRowTy f rows
    TyList t -> TyList <$> f t
    TyTable r -> TyTable <$> traverseRowTy f r
    TyCap -> pure TyCap
    -- TyInterface n ->
    --   pure $ TyInterface n
    -- TyModule n -> pure $ TyModule n
    TCTyCon b tv -> pure (TCTyCon b tv)
    TyForall ns ty ->
      TyForall ns <$> f ty


typeOfLit :: Literal -> Type n
typeOfLit = TyPrim . \case
  LString{} -> PrimString
  LInteger{} -> PrimInt
  LDecimal{} -> PrimDecimal
  LBool{} -> PrimBool
  LTime{} -> PrimTime
  LUnit -> PrimUnit

instance Pretty n => Pretty (InterfaceType n) where
  pretty (InterfaceType n) = pretty n

instance Pretty n => Pretty (Row n) where
  pretty = \case
    EmptyRow -> "{}"
    RowVar rv -> Pretty.braces (pretty rv)
    RowTy obj n ->
      Pretty.braces $ renderObj (Map.toList obj) <+> renderRv n
      where
      renderObj li =
        Pretty.hsep $ Pretty.punctuate Pretty.comma $ fmap (\(f, t) -> pretty f <> ":" <+> pretty t) li
      renderRv = \case
        Just v -> "|" <+> pretty v
        Nothing -> mempty

instance Pretty n => Pretty (Pred n) where
  pretty (Pred tc ty) = case tc of
    WithoutField f ->
      Pretty.parens (pretty f <> "\\" <> pretty ty)
    _ -> pretty tc <>  Pretty.angles (pretty ty)

instance Pretty n => Pretty (Type n) where
  pretty = \case
    TyVar n -> pretty n
    TyPrim p -> pretty p
    TyFun l r -> fnParens l <+> "->" <+> pretty r
      where
        fnParens t@TyFun{} = Pretty.parens (pretty t)
        fnParens t@TyForall{} = Pretty.parens (pretty t)
        fnParens t = pretty t
    TyList l -> "list" <+> liParens l
      where
      liParens t@TyVar{} = pretty t
      liParens t@TyPrim{} = pretty t
      liParens t@TyCap = pretty t
      liParens t = Pretty.parens (pretty t)
    TyRow r -> pretty r
    TyTable t -> "table" <+> Pretty.parens (pretty t)
    TyCap -> "capability"
    -- TyInterface i -> "module" <> Pretty.angles (pretty i)
    TCTyCon b tv -> case b of
      WithoutField f ->
        Pretty.parens (pretty tv <> "\\" <> pretty f)
      _ -> pretty b <> pretty tv
    TyForall as ty ->
      "∀" <> render (NE.toList as) "TYPE"  <> "." <> pretty ty
      where
      render xs suffix =
        Pretty.hsep $ fmap (\n -> Pretty.parens (pretty n <> ":" <+> suffix)) xs
