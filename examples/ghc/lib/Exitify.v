(* Default settings (from HsToCoq.Coq.Preamble) *)

Generalizable All Variables.

Unset Implicit Arguments.
Set Maximal Implicit Insertion.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Require Coq.Program.Tactics.
Require Coq.Program.Wf.

(* Converted imports: *)

Require BasicTypes.
Require Combined.
Require Coq.Init.Datatypes.
Require CoreFVs.
Require Data.Bifunctor.
Require Data.Foldable.
Require Data.Traversable.
Require Data.Tuple.
Require FastString.
Require GHC.Base.
Require GHC.DeferredFix.
Require GHC.List.
Require Id.
Require Panic.
Require State.
Require Unique.
Import GHC.Base.Notations.

(* Converted type declarations: *)

Definition ExitifyM :=
  (State.State (list (Combined.JoinId * Combined.CoreExpr)%type))%type.
(* Converted value declarations: *)

Definition mkExitJoinId
   : Combined.InScopeSet ->
     unit -> BasicTypes.JoinArity -> ExitifyM Combined.JoinId :=
  fun in_scope ty join_arity =>
    let exit_occ_info :=
      BasicTypes.OneOcc true true false (BasicTypes.AlwaysTailCalled join_arity) in
    let exit_id_tmpl :=
      Id.setIdOccInfo (Id.asJoinId (Id.mkSysLocal (FastString.fsLit
                                                   (GHC.Base.hs_string__ "exit")) Unique.initExitJoinUnique ty)
                                   join_arity) exit_occ_info in
    State.get GHC.Base.>>=
    (fun fs =>
       let avoid :=
         Combined.extendInScopeSet (Combined.extendInScopeSetList in_scope (GHC.Base.map
                                                                   Data.Tuple.fst fs)) exit_id_tmpl in
       GHC.Base.return_ (Combined.uniqAway avoid exit_id_tmpl)).

Definition addExit
   : Combined.InScopeSet ->
     unit -> BasicTypes.JoinArity -> Combined.CoreExpr -> ExitifyM Combined.JoinId :=
  fun in_scope ty join_arity rhs =>
    mkExitJoinId in_scope ty join_arity GHC.Base.>>=
    (fun v =>
       State.get GHC.Base.>>=
       (fun fs => State.put (cons (pair v rhs) fs) GHC.Base.>> GHC.Base.return_ v)).

Definition exitify
   : Combined.InScopeSet ->
     list (Combined.Var * Combined.CoreExpr)%type ->
     (Combined.CoreExpr -> Combined.CoreExpr) :=
  fun in_scope pairs =>
    let recursive_calls := Combined.mkVarSet (GHC.Base.map Data.Tuple.fst pairs) in
    let go
     : list Combined.Var ->
       CoreFVs.CoreExprWithFVs ->
       State.State (list (Combined.Var * Combined.CoreExpr)%type) Combined.CoreExpr :=
      GHC.DeferredFix.deferredFix2 (fun go arg_1__ arg_2__ =>
                                      match arg_1__, arg_2__ with
                                      | captured, ann_e =>
                                          let j_4__ :=
                                            match arg_1__, arg_2__ with
                                            | _, ann_e => GHC.Base.return_ (Combined.deAnnotate ann_e)
                                            end in
                                          let j_22__ :=
                                            match arg_1__, arg_2__ with
                                            | captured, pair _ (Combined.AnnCase scrut bndr ty alts) =>
                                                Data.Traversable.forM alts (fun '(pair (pair dc pats) rhs) =>
                                                                              go (Coq.Init.Datatypes.app captured
                                                                                                         (Coq.Init.Datatypes.app
                                                                                                          (cons bndr
                                                                                                                nil)
                                                                                                          pats)) rhs
                                                                              GHC.Base.>>=
                                                                              (fun rhs' =>
                                                                                 GHC.Base.return_ (pair (pair dc pats)
                                                                                                        rhs')))
                                                GHC.Base.>>=
                                                (fun alts' =>
                                                   GHC.Base.return_ (Combined.Case (Combined.deAnnotate scrut) bndr ty
                                                                                   alts'))
                                            | captured, pair _ (Combined.AnnLet ann_bind body) =>
                                                let bind := Combined.deAnnBind ann_bind in
                                                let j_10__ :=
                                                  go (Coq.Init.Datatypes.app captured (Combined.bindersOf bind)) body
                                                  GHC.Base.>>=
                                                  (fun body' => GHC.Base.return_ (Combined.Let bind body')) in
                                                let j_18__ :=
                                                  match ann_bind with
                                                  | Combined.AnnRec pairs =>
                                                      if Id.isJoinId (Data.Tuple.fst (Panic.head pairs)) : bool
                                                      then let js := GHC.Base.map Data.Tuple.fst pairs in
                                                           Data.Traversable.forM pairs (fun '(pair j rhs) =>
                                                                                          let join_arity :=
                                                                                            Id.idJoinArity j in
                                                                                          let 'pair params join_body :=
                                                                                            Combined.collectNAnnBndrs
                                                                                              join_arity rhs in
                                                                                          go (Coq.Init.Datatypes.app
                                                                                              captured
                                                                                              (Coq.Init.Datatypes.app js
                                                                                                                      params))
                                                                                          join_body GHC.Base.>>=
                                                                                          (fun join_body' =>
                                                                                             let rhs' :=
                                                                                               Combined.mkLams params
                                                                                               join_body' in
                                                                                             GHC.Base.return_ (pair j
                                                                                                                    rhs')))
                                                           GHC.Base.>>=
                                                           (fun pairs' =>
                                                              go (Coq.Init.Datatypes.app captured js) body GHC.Base.>>=
                                                              (fun body' =>
                                                                 GHC.Base.return_ (Combined.Let (Combined.Rec pairs')
                                                                                                body'))) else
                                                      j_10__
                                                  | _ => j_10__
                                                  end in
                                                match ann_bind with
                                                | Combined.AnnNonRec j rhs =>
                                                    match Id.isJoinId_maybe j with
                                                    | Some join_arity =>
                                                        let 'pair params join_body := Combined.collectNAnnBndrs
                                                                                        join_arity rhs in
                                                        go (Coq.Init.Datatypes.app captured params) join_body
                                                        GHC.Base.>>=
                                                        (fun join_body' =>
                                                           let rhs' := Combined.mkLams params join_body' in
                                                           go (Coq.Init.Datatypes.app captured (cons j nil)) body
                                                           GHC.Base.>>=
                                                           (fun body' =>
                                                              GHC.Base.return_ (Combined.Let (Combined.NonRec j rhs')
                                                                                             body')))
                                                    | _ => j_18__
                                                    end
                                                | _ => j_18__
                                                end
                                            | _, _ => j_4__
                                            end in
                                          let fvs := Combined.dVarSetToVarSet (CoreFVs.freeVarsOf ann_e) in
                                          let e := Combined.deAnnotate ann_e in
                                          let args :=
                                            GHC.List.filter (fun arg_25__ => Combined.elemVarSet arg_25__ fvs)
                                            captured in
                                          let captures_join_points := Data.Foldable.any Id.isJoinId args in
                                          let is_interesting :=
                                            Combined.anyVarSet Combined.isLocalId (Combined.minusVarSet fvs
                                                                                                        (Combined.mkVarSet
                                                                                                         captured)) in
                                          let isCapturedVarArg :=
                                            fun arg_29__ =>
                                              match arg_29__ with
                                              | Combined.Mk_Var v => Data.Foldable.elem v captured
                                              | _ => false
                                              end in
                                          let is_exit := Combined.disjointVarSet fvs recursive_calls in
                                          let j_35__ :=
                                            if is_exit : bool
                                            then let rhs := Combined.mkLams args e in
                                                 let ty := tt in
                                                 let avoid := Combined.extendInScopeSetList in_scope captured in
                                                 addExit avoid ty (Data.Foldable.length args) rhs GHC.Base.>>=
                                                 (fun v =>
                                                    GHC.Base.return_ (Combined.mkVarApps (Combined.Mk_Var v) args)) else
                                            j_22__ in
                                          let j_36__ :=
                                            if andb is_exit captures_join_points : bool then GHC.Base.return_ e else
                                            j_35__ in
                                          let j_37__ :=
                                            if andb is_exit (negb is_interesting) : bool then GHC.Base.return_ e else
                                            j_36__ in
                                          match Combined.collectArgs e with
                                          | pair (Combined.Mk_Var f) args =>
                                              if andb (Id.isJoinId f) (Data.Foldable.all isCapturedVarArg args) : bool
                                              then GHC.Base.return_ e else
                                              j_37__
                                          | _ => j_37__
                                          end
                                      end) in
    let ann_pairs := GHC.Base.map (Data.Bifunctor.second CoreFVs.freeVars) pairs in
    let 'pair pairs' exits := (fun arg_41__ => State.runState arg_41__ nil)
                                (Data.Traversable.forM ann_pairs (fun '(pair x rhs) =>
                                                          let 'pair args body := Combined.collectNAnnBndrs
                                                                                   (Id.idJoinArity x) rhs in
                                                          go args body GHC.Base.>>=
                                                          (fun body' =>
                                                             let rhs' := Combined.mkLams args body' in
                                                             GHC.Base.return_ (pair x rhs')))) in
    let fix mkExitLets arg_48__
              := match arg_48__ with
                 | cons (pair exitId exitRhs) exits' =>
                     Combined.mkLetNonRec exitId exitRhs GHC.Base.∘ mkExitLets exits'
                 | nil => GHC.Base.id
                 end in
    fun body => mkExitLets exits (Combined.mkLetRec pairs' body).

(* External variables:
     Some andb bool cons false list negb nil op_zt__ pair true tt unit
     BasicTypes.AlwaysTailCalled BasicTypes.JoinArity BasicTypes.OneOcc
     Combined.AnnCase Combined.AnnLet Combined.AnnNonRec Combined.AnnRec
     Combined.Case Combined.CoreExpr Combined.InScopeSet Combined.JoinId Combined.Let
     Combined.Mk_Var Combined.NonRec Combined.Rec Combined.Var Combined.anyVarSet
     Combined.bindersOf Combined.collectArgs Combined.collectNAnnBndrs
     Combined.dVarSetToVarSet Combined.deAnnBind Combined.deAnnotate
     Combined.disjointVarSet Combined.elemVarSet Combined.extendInScopeSet
     Combined.extendInScopeSetList Combined.isLocalId Combined.minusVarSet
     Combined.mkLams Combined.mkLetNonRec Combined.mkLetRec Combined.mkVarApps
     Combined.mkVarSet Combined.uniqAway Coq.Init.Datatypes.app
     CoreFVs.CoreExprWithFVs CoreFVs.freeVars CoreFVs.freeVarsOf
     Data.Bifunctor.second Data.Foldable.all Data.Foldable.any Data.Foldable.elem
     Data.Foldable.length Data.Traversable.forM Data.Tuple.fst FastString.fsLit
     GHC.Base.id GHC.Base.map GHC.Base.op_z2218U__ GHC.Base.op_zgzg__
     GHC.Base.op_zgzgze__ GHC.Base.return_ GHC.DeferredFix.deferredFix2
     GHC.List.filter Id.asJoinId Id.idJoinArity Id.isJoinId Id.isJoinId_maybe
     Id.mkSysLocal Id.setIdOccInfo Panic.head State.State State.get State.put
     State.runState Unique.initExitJoinUnique
*)