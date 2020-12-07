{-# LANGUAGE CPP, FlexibleContexts, OverloadedStrings #-}

#include "ghc-compat.h"

module HsToCoq.ConvertHaskell.Type (convertType, convertPredType) where

import Data.List.NonEmpty (NonEmpty(..))
import Control.Lens

import TyCoRep
import TyCon
import Type (isPredTy)
import Name (getName)

import HsToCoq.Coq.Gallina as Coq
import HsToCoq.Coq.Gallina.Util
import HsToCoq.Edits.Types

import HsToCoq.ConvertHaskell.Variables
import HsToCoq.ConvertHaskell.Literals
import HsToCoq.ConvertHaskell.Monad

convertTyConApp :: ConversionMonad r m => Bool -> TyCon -> [KindOrType] -> Qualid -> m Term
convertTyConApp b tc ts ctc = do
  let cond = if b then const True else isVisibleTyConBinder . fst
  ts' <- mapM (convertType . snd) $ filter cond $ zip (tyConBinders tc) ts
  case ts' of
    ct : cts' -> pure $ App (Qualid ctc) $ PosArg <$> (ct :| cts')
    _         -> pure $ Qualid ctc

convertType' :: ConversionMonad r m => Bool -> Type -> m Term
convertType' _ (TyVarTy tv) = Qualid <$> var TypeNS (getName tv)
convertType' b (AppTy ty1 ty2) = App1 <$> convertType' b ty1 <*> convertType' b ty2
convertType' _ (TyConApp tc []) = Qualid <$> convertTyCon tc
convertType' b (TyConApp tc ts@(_:_)) = do
  convertedTc <- convertTyCon tc
  case convertedTc of
    (Qualified m t) | m == "GHC.Prim" && t == "TYPE"
                      -> pure $ Qualid (Bare "Type")
                    | m == "GHC.Tuple" && (t == "pair_type" || t == "op_Z2T__") && length ts > 1
                      -> (`InScope` "type") . foldl1 (mkInfix ?? "*") <$> traverse (convertType' b) ts
    _ -> convertTyConApp b tc ts convertedTc
convertType' b (ForAllTy tv ty) = do
  convertedTv <- convertTyVarBinder Coq.Implicit tv
  convertedTy <- convertType' b ty
  pure $ Forall (convertedTv :| []) convertedTy
convertType' b (FunTy ty1 ty2) | isPredTy ty1 = do
                                cons <- convertPredType ty1
                                Forall (Generalized Coq.Implicit cons :| []) <$> convertType' b ty2
                            | otherwise    = Arrow <$> convertType' b ty1 <*> convertType' b ty2
convertType' _ (LitTy tl) = case tl of
  NumTyLit int -> either convUnsupported' (pure . Num) $ convertInteger "type-level integers" int
  StrTyLit str -> pure $ convertFastString str
convertType' _ (CastTy _ty _coercion) = convUnsupported' "Kind cast"
convertType' _ (CoercionTy _coercion) = convUnsupported' "Injection of a Coercion into a type"
  
convertType :: ConversionMonad r m => Type -> m Term
convertType = convertType' False

convertKind :: ConversionMonad r m => Kind -> m Term
convertKind = convertType' False

convertPredType :: ConversionMonad r m => Kind -> m Term
convertPredType = convertType' True

convertTyCon :: ConversionMonad r m => TyCon -> m Qualid
convertTyCon tc = var TypeNS $ getName tc

convertTyVarBinder :: ConversionMonad r m => Explicitness -> TyVarBinder -> m Binder
convertTyVarBinder ex bndr = do
  tv <- Ident <$> var TypeNS (getName $ binderVar bndr)
  tk <- convertKind $ binderKind bndr
  pure $ mkBinders ex (tv :| []) tk
