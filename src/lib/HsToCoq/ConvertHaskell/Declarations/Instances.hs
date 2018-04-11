{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections, LambdaCase, RecordWildCards,
             OverloadedStrings,
             ScopedTypeVariables,
             FlexibleContexts #-}

module HsToCoq.ConvertHaskell.Declarations.Instances (
  -- * Top-level entry point
  convertClsInstDecls,
  -- * Axiomatizing equivalents
  axiomatizeClsInstDecls,
) where

import Control.Lens

import Data.Semigroup (Semigroup(..), (<>))
import Data.Traversable
import HsToCoq.Util.Traversable
import Data.Maybe
import qualified Data.List.NonEmpty as NE
import Data.Bifunctor
import qualified Data.Text as T

import Control.Monad.State

import qualified Data.Map.Strict as M
import qualified Data.Set as S

import GHC hiding (Name)
import Bag
import HsToCoq.Util.GHC.Exception
import HsToCoq.Util.GHC.Module

import HsToCoq.Coq.Gallina
import HsToCoq.Coq.FreeVars
import HsToCoq.Coq.Subst
import HsToCoq.Coq.Gallina.Util

import HsToCoq.ConvertHaskell.Monad
import HsToCoq.ConvertHaskell.TypeInfo
import HsToCoq.ConvertHaskell.Definitions
import HsToCoq.ConvertHaskell.Parameters.Edits
import HsToCoq.ConvertHaskell.Type
import HsToCoq.ConvertHaskell.Expr
import HsToCoq.ConvertHaskell.Axiomatize
import HsToCoq.ConvertHaskell.Declarations.Class

--------------------------------------------------------------------------------

-- Take the instance head and make it into a valid identifier.
convertInstanceName :: ConversionMonad r m => LHsType GhcRn -> m Qualid
convertInstanceName n = do
    coqType <- convertLType n
    qual <- Qualified . moduleNameText <$> view currentModule
    case skip coqType of
        Left err -> convUnsupported $ "Cannot derive instance name from " ++ show coqType ++ ": " ++ err
        Right name -> return $ qual name
  where
    -- Skip type vaiables and constraints
    skip (Forall _ t)  = skip t
    skip (Arrow _ t)   = skip t
    skip (InScope t _) = skip t
    skip t             = bfToName <$> bfTerm t

    bfToName :: [Qualid] -> T.Text
    bfToName qids | isVanilla = name
                  | otherwise = name <> "__" <> T.pack (show shapeNum)
      where
        tyCons = [ bn | Just bn <- unTyCon <$> qids]
        name = T.intercalate "__" tyCons
        shapeNum = bitsToInt $ map isTyCon qids

        -- A vanilla header is when all tyCons appear before all
        -- type variables. In this case, do not add the shapeNum
        isVanilla = not $ any isTyCon $ dropWhile isTyCon $ qids

        isTyCon = isJust . unTyCon

        unTyCon :: Qualid -> Maybe T.Text
        unTyCon (Qualified _ base)  = Just base
        unTyCon (Bare "bool")       = Just "bool"
        unTyCon (Bare "comparison") = Just "comparison"
        unTyCon (Bare "list")       = Just "list"
        unTyCon (Bare "option")     = Just "option"
        unTyCon (Bare "op_zt__")    = Just "op_zt__"
        unTyCon (Bare "unit")       = Just "unit"
        unTyCon _                   = Nothing

        bitsToInt :: [Bool] -> Integer
        bitsToInt []         = 0
        bitsToInt (True:xs)  = 2*bitsToInt xs + 1
        bitsToInt (False:xs) = 2*bitsToInt xs

    -- Breadth-first traversal listing all variables and type constructors
    bfTerm :: Monad m => Term -> m [Qualid]
    bfTerm = fmap concat . go
      where
        go :: Monad m => Term -> m [[Qualid]]
        go t = do
            (f, args) <- collectArgs t
            subtrees <- mapM go args
            return $ [f] : foldr merge [] subtrees

    merge :: [[a]] -> [[a]] -> [[a]]
    merge xs     []     = xs
    merge []     ys     = ys
    merge (x:xs) (y:ys) = (x ++ y) : merge xs ys

--------------------------------------------------------------------------------
{- Haskell:
      instance Functor ((->) r)
   InstanceInfo
      Name = "Functor__arr_r___"
      Head = "Functor (_(->)_ r)" as a Coq term, with free variable
      Class = "Functor"

   Haskell:
      instance Eq a => Eq [a]
   InstanceInfo
      Name = "Eq_list____"
      Head = "forall `{Eq a}, Eq (list a)"
      Class = "Eq"

-}
data InstanceInfo = InstanceInfo { instanceName       :: !Qualid
                                 , instanceHead       :: !Term
                                 , instanceClass      :: !Qualid
                                 }
                  deriving (Eq, Ord)

convertClsInstDeclInfo :: ConversionMonad r m => ClsInstDecl GhcRn -> m InstanceInfo
convertClsInstDeclInfo ClsInstDecl{..} = do
  instanceName  <- convertInstanceName $ hsib_body cid_poly_ty
  instanceHead  <- convertLHsSigType cid_poly_ty
  instanceClass <- maybe (convUnsupported "strangely-formed instance heads") pure $
                    termHead instanceHead

  pure InstanceInfo{..}

--------------------------------------------------------------------------------

unlessSkipped :: ConversionMonad r m => InstanceInfo -> m [Sentence] -> m [Sentence]
unlessSkipped (InstanceInfo{..}) act = do
  view (edits.skipped.contains instanceClass) >>= \case
    True -> pure [ CommentSentence (Comment ("Skipping instance " <> qualidBase instanceName <> " of class " <> qualidBase instanceClass)) ]
    False -> do
      view (edits.skipped.contains instanceName) >>= \case
        True -> pure [ CommentSentence (Comment ("Skipping instance " <> qualidBase instanceName)) ]
        False -> act

convertClsInstDecl :: ConversionMonad r m => ClsInstDecl GhcRn -> m [Sentence]
convertClsInstDecl cid@ClsInstDecl{..} = do
  ii@InstanceInfo{..} <- convertClsInstDeclInfo cid

  let err_handler exn = pure [ translationFailedComment ("instance " <> qualidBase instanceName) exn ]
  unlessSkipped ii $ ghandle err_handler $ do
    cbinds <- fmap catMaybes $ mapM (convertTypedModuleBinding Nothing) $ map unLoc $ bagToList cid_binds
    cdefs <-  forM cbinds $ \case
        ConvertedDefinitionBinding (ConvertedDefinition{..})
            -> return (convDefName, maybe id Fun (NE.nonEmpty (convDefArgs)) $ convDefBody)
        ConvertedPatternBinding{} -> convUnsupported "pattern bindings in instances"

    defaults <-  fromMaybe M.empty <$> lookupDefaultMethods instanceClass
                 -- lookup default methods in the global state, using the
                 -- empty map if the class name is not found
                 -- otherwise gives you a map
                 -- <&> is flip fmap
             <&> filter (\(meth, _) -> isNothing $ lookup meth cdefs) . M.toList

    -- implement the instance part of "skip method"
    skippedMethodsS <- view (edits.skippedMethods)

    let methods = filter (\(m,_) -> (instanceClass,qualidBase m) `S.notMember` skippedMethodsS) (cdefs ++ defaults)

    let (binds, classTy) = decomposeForall instanceHead

    -- decomposeClassTy can fail, so run it in the monad so that
    -- failure will be caugh cause the instance to be skipped
    (className, instTy) <- decomposeClassTy classTy

    topoSortInstance instanceName binds className instTy methods


axiomatizeClsInstDecl :: ConversionMonad r m
                      => ClsInstDecl GhcRn        -- Haskell instance we are converting
                      -> m [Sentence]
axiomatizeClsInstDecl cid@ClsInstDecl{..} = do
  ii@InstanceInfo{..} <- convertClsInstDeclInfo cid
  unlessSkipped ii $ do
      lookupClassDefn instanceClass >>= \case
        Just (ClassDefinition _ _ _ methods) ->
          pure $ [ InstanceSentence $ InstanceDefinition instanceName [] instanceHead []
                                    $ if null methods then Nothing else Just $ ProofAdmitted "" ]
        Nothing ->
          -- convUnsupported ("OOPS! Cannot find information for class " ++ show instanceClass)
          pure []

--------------------------------------------------------------------------------

convertClsInstDecls, axiomatizeClsInstDecls :: forall r m. ConversionMonad r m =>
    [ClsInstDecl GhcRn] -> m [Sentence]
convertClsInstDecls = foldTraverse convertClsInstDecl
axiomatizeClsInstDecls = foldTraverse axiomatizeClsInstDecl

--------------------------------------------------------------------------------

-- Topo sort the instance members and lift (some of) them outside of
-- the instance declaration.

topoSortInstance :: forall r m. ConversionMonad r m =>
    Qualid -> [Binder] -> Qualid -> Term -> [(Qualid,Term)] -> m [Sentence]
topoSortInstance instanceName params className instTy members = go sorted M.empty where

        m        = M.fromList members
        sorted   = topoSortEnvironment m
{-
        getFreeVarsIdent :: Ident -> S.Set Ident
        getFreeVarsIdent m = maybe S.empty getFreeVars (lookup m members)

        getFreeVarsNE :: NE.NonEmpty Ident -> S.Set Ident
        getFreeVarsNE ne = S.unions (map getFreeVarsIdent (NE.toList ne))

        containsNE :: NE.NonEmpty Ident -> S.Set Ident -> Bool
        containsNE ne s = any (\v -> S.member v s) ne

        compressLast :: [ NE.NonEmpty Ident ] -> ([ NE.NonEmpty Ident ], S.Set Ident)
        compressLast [ ]      = ([], S.empty)
        compressLast (h : []) =
            ([h], getFreeVarsNE h)
        compressLast (h : tl) =
            let extend set = S.union set (getFreeVarsNE h) in
            case compressLast tl of
              ([],s)         -> error "BUG: this case is impossible"
              ((h':[]), set) ->
                  if containsNE h set then
                      ([h , h'], extend set)
                  else
                      ([h <> h'], extend set)
              ((h':tl'), set) ->
                          (h : h' : tl', S.empty) -- don't care anymore
-}
        -- go through the toposort of members, constructing the final sentences
        go :: [ NE.NonEmpty Qualid ] -> M.Map Qualid Qualid -> m [ Sentence ]

        go []      sub = mkID sub
        go (hd:tl) sub = do (s1,bnds) <- mkDefnGrp (NE.toList hd) sub
                            s2        <- go tl bnds
                            return (s1 ++ s2)


        buildName = qualidExtendBase "__Dict_Build" className

        -- lookup the type of the class member
        -- add extra quantifiers from the class & instance definitions
        mkTy :: Qualid -> m ([Binder], Maybe Term)
        mkTy memberName = do
          classDef <- lookupClassDefn className
          case classDef of
            (Just (ClassDefinition _ (b:_) _ sigs)) | [var] <- toListOf binderIdents b ->
              case lookup memberName sigs of
                Just sigType ->
                  -- GOAL: Consider
                  -- @
                  --     class Functor f where
                  --       fmap :: (a -> b) -> f a -> f b
                  --     instance Functor (Either a) where fmap = ...
                  -- @
                  -- When desugared naïvely into Coq, this will result in a term with type
                  -- @
                  --     forall {a₁}, forall {a₂ b},
                  --       (a₂ -> b) -> f (Either a₁ a₂) -> f (Either a₁ b)
                  -- @
                  -- Except without the subscripts!  So we have to rename either
                  -- the per-instance variables (here, @a₁@) or the type class
                  -- method variables (here, @a₂@ and @b@).  We pick the
                  -- per-instance variables, and rename @a₁@ to @inst_a₁@.
                  --
                  -- ASSUMPTION: type variables don't show up in terms.  Broken
                  -- by ScopedTypeVariables.
                  let renameInst UnderscoreName =
                        pure UnderscoreName
                      renameInst (Ident x) =
                        let inst_x = qualidMapBase ("inst_" <>) x
                        in Ident inst_x <$ modify' (M.insert x (Qualid inst_x))

                      sub ty = ($ ty) <$> gets subst

                      (instBnds, instSubst) = (runState ?? M.empty) $ for params $ \case
                        Inferred      ei x     -> Inferred      ei <$> renameInst x
                        Typed       g ei xs ty -> Typed       g ei <$> traverse renameInst xs <*> sub ty
                        Generalized ei tm      -> Generalized   ei <$> sub tm

                      -- Why the nested substitution?  The only place the
                      -- per-instance variable name can show up is in the
                      -- specific instance type!  It can't show up in the
                      -- signature of the method, that's the whole point
                      instSigType = subst (M.singleton var $ subst instSubst instTy) sigType
                  in pure $ (instBnds, Just $ instSigType)
                Nothing ->
                  convUnsupported ("Cannot find sig for " ++ show memberName)
            _ -> convUnsupported ("OOPS! Cannot find information for class " ++ show className)

        -- Methods often look recursive, but usually they are not really,
        -- so by default, we un-do the fix introduced by convertTypedBinding
        unFix :: Term -> Term
        unFix body = case body of
            Fun bnds t -> Fun bnds (unFix t)
            Fix (FixOne (FixBody _ bnds _ _ body'))
              -> Fun bnds body'
            App1 (Qualid fun) (Fun (Inferred Explicit (Ident _) NE.:| bnds) body')
                | "deferredFix" `T.isPrefixOf` qualidBase fun
              -> Fun (NE.fromList bnds) body'
            _ -> body

        -- Gets the class method names, in the original
        getClassMethods = do
          classDef <- lookupClassDefn className
          case classDef of
            (Just (ClassDefinition _ _ _ sigs)) ->
                pure $ map fst sigs
            _ -> convUnsupported ("OOPS! Cannot find information for class " ++ show className)

        -- This is the variant
        --   {| foo := fun {a} {b} => instance_foo |}
        -- which is too much for Coq’s type inference (without Program mode), see
        -- https://sympa.inria.fr/sympa/arc/coq-club/2017-11/msg00035.html
        quantify :: Qualid -> Term -> m Term
        quantify meth body =
            do typeArgs <- getImplicitBindersForClassMember className meth
               case (NE.nonEmpty typeArgs) of
                   Nothing -> return body
                   Just args -> return $ Fun args body

        -- This is the variant
        --   {| foo := @instance_foo _ _ |}
        -- which works only if params really are all arguments (no [{a} `{MonadArrow a}])
        _addArgs _meth impl = return $ ExplicitApp (Bare impl) (Underscore <$ params)

        -- given a group of member ids turn them into lifted definitions, keeping track of the current
        -- substitution
        mkDefnGrp :: [ Qualid ] -> (M.Map Qualid Qualid) -> m ([ Sentence ], M.Map Qualid Qualid)
        mkDefnGrp [] sub = return ([], sub)
        mkDefnGrp [ v ] sub = do
           let v' = qualidMapBase (<> ("_" <> qualidBase v)) instanceName
           (params, mty)  <- mkTy v
           body <- quantify v (subst (fmap Qualid sub) (m M.! v))
           let sub' = M.insert v v' sub

           -- implement redefinitions of methods
           view (edits.redefinitions.at v') >>= \case
               Just redef -> pure ([ definitionSentence redef], sub')
               Nothing    -> pure ([ DefinitionSentence (DefinitionDef Local v' params mty (unFix body)) ], sub')

        mkDefnGrp many _sub =
           -- TODO: mutual recursion
           convUnsupported ("Giving up on mutual recursion" ++ show many)

        -- make the final instance declaration, using the current substitution as the instance
        mkID :: M.Map Qualid Qualid -> m [ Sentence ]
        mkID mems = do
            view (edits.redefinitions.at instanceName) >>= \case
                Nothing -> do
                    -- Assemble members in the right order
                    classMethods <- getClassMethods

                    mems' <- forM classMethods $ \v -> do
                        case M.lookup v mems of
                          Just v' -> do
                              t <- quantify v (Qualid v')
                              pure $ ((qualidMapBase (<> "__") v), t)
                          Nothing -> convUnsupported ("missing " ++ show v ++ " in " ++ show mems )

                    -- When we can use record syntax, we can use this.
                    -- `Instance` plus record syntax does sometimes not work,
                    -- but `Program Instance` does.
                    let body = Record mems'

                    -- This variant uses the explicit `Build` command, which does
                    -- works with `Instance`, but is ugly
                    let _body = appList (Qualid buildName) $ map PosArg $
                            [ instTy ] ++ map snd mems'


                    let instHeadTy = appList (Qualid className) [PosArg instTy]
                    let instTerm = Fun (Inferred Explicit UnderscoreName NE.:| [Inferred Explicit (Ident "k")])
                                       (App1 (Var "k") body)

                    pure [ProgramSentence (InstanceSentence (InstanceTerm instanceName params instHeadTy instTerm Nothing)) Nothing]
                Just (CoqInstanceDef x) -> pure [InstanceSentence x]
                Just redef -> editFailure $ ("cannot redefine an Instance Definition to be " ++) $
                        case redef of CoqDefinitionDef       _ -> "a Definition"
                                      CoqFixpointDef         _ -> "a Fixpoint"
                                      CoqInductiveDef        _ -> "an Inductive"
                                      CoqInstanceDef         _ -> "an Instance Definition"

-- from "instance C ty where" access C and ty
-- TODO: multiparameter type classes   "instance C t1 t2 where"
--       instances with contexts       "instance C a => C (Maybe a) where"
decomposeClassTy :: ConversionMonad r m => Term -> m (Qualid, Term)
decomposeClassTy ty = case ty of
   App1 (Qualid cn) a -> pure (cn, a)
   _ -> convUnsupported ("type class instance head:" ++ show ty)

decomposeForall :: Term -> ([Binder], Term)
decomposeForall (Forall bnds ty) = first (NE.toList bnds ++) (decomposeForall ty)
decomposeForall t = ([], t)
