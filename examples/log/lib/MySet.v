(* Default settings (from HsToCoq.Coq.Preamble) *)

Generalizable All Variables.

Unset Implicit Arguments.
Set Maximal Implicit Insertion.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Require Coq.Program.Tactics.
Require Coq.Program.Wf.

(* Converted imports: *)

Require Coq.Init.Datatypes.
Require Data.Foldable.
Require GHC.Base.
Require GHC.List.
Import GHC.Base.Notations.

(* Converted type declarations: *)

Inductive Set_ a : Type := | MkSet : list a -> Set_ a.

Arguments MkSet {_} _.

(* Converted value declarations: *)

Definition singleton {a} : a -> Set_ a :=
  fun a => MkSet (cons a nil).

Definition powerSet {a} : Set_ a -> Set_ (Set_ a) :=
  fun s => singleton s.

Definition member {a} `{GHC.Base.Eq_ a} : a -> Set_ a -> bool :=
  fun arg_0__ arg_1__ =>
    match arg_0__, arg_1__ with
    | a, MkSet s => Data.Foldable.any (_GHC.Base.==_ a) s
    end.

Definition union {a} `{GHC.Base.Eq_ a} : Set_ a -> Set_ a -> Set_ a :=
  fun arg_0__ arg_1__ =>
    match arg_0__, arg_1__ with
    | MkSet s1, MkSet s2 =>
        MkSet (Coq.Init.Datatypes.app s1 (GHC.List.filter (fun x =>
                                                             negb (member x (MkSet s1))) s2))
    end.

Definition empty {a} : Set_ a :=
  MkSet nil.

Definition add {a} `{GHC.Base.Eq_ a} : a -> Set_ a -> Set_ a :=
  fun arg_0__ arg_1__ =>
    match arg_0__, arg_1__ with
    | a, MkSet s => if member a (MkSet s) : bool then MkSet s else MkSet (cons a s)
    end.

(* External variables:
     bool cons list negb nil Coq.Init.Datatypes.app Data.Foldable.any GHC.Base.Eq_
     GHC.Base.op_zeze__ GHC.List.filter
*)
