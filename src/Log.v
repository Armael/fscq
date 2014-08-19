Require Import Arith.
Require Import Omega.
Require Import List.
Require Import Prog.
Require Import Pred.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.

Set Implicit Arguments.


(** * A log-based transactions implementation *)

Definition disjoint (r1 : addr * nat) (r2 : addr * nat) :=
  forall a, fst r1 <= a < fst r1 + snd r1
    -> ~(fst r2 <= a < fst r2 + snd r2).

Fixpoint disjoints (rs : list (addr * nat)) :=
  match rs with
    | nil => True
    | r1 :: rs => Forall (disjoint r1) rs /\ disjoints rs
  end.

Record xparams := {
  DataStart : addr; (* The actual committed data start at this disk address. *)
    DataLen : nat;  (* Size of data region *)

  LogLength : addr; (* Store the length of the log here. *)
  LogCommit : addr; (* Store true to apply after crash. *)

   LogStart : addr; (* Start of log region on disk *)
     LogLen : nat;  (* Size of log region *)

   Disjoint : disjoints ((DataStart, DataLen)
     :: (LogLength, 1)
     :: (LogCommit, 1)
     :: (LogStart, LogLen*2)
     :: nil)
}.

Ltac disjoint' xp :=
  generalize (Disjoint xp); simpl; intuition;
    repeat match goal with
             | [ H : True |- _ ] => clear H
             | [ H : Forall _ nil |- _ ] => clear H
             | [ H : Forall _ (_ :: _) |- _ ] => inversion_clear H
           end; unfold disjoint in *; simpl in *; subst.

Ltac disjoint'' a :=
  match goal with
    | [ H : forall a', _ |- _ ] => specialize (H a); omega
  end.

Ltac disjoint xp :=
  disjoint' xp;
  match goal with
    | [ _ : _ <= ?n |- _ ] => disjoint'' n
    | [ _ : _ = ?n |- _ ] => disjoint'' n
  end.

Hint Rewrite upd_eq upd_ne using (congruence
  || match goal with
       | [ xp : xparams |- _ ] => disjoint xp
     end).

Definition diskIs (m : mem) : pred := eq m.
Hint Extern 1 (okToUnify (diskIs _) (diskIs _)) => constructor : okToUnify.
(* XXX the above unification rule might help us deal with array predicates *)

Inductive logstate :=
| NoTransaction (cur : mem)
(* Don't touch the disk directly in this state. *)
| ActiveTxn (old : mem) (cur : mem)
(* A transaction is in progress.
 * It started from the first memory and has evolved into the second.
 * It has not committed yet. *)
| CommittedTxn (cur : mem)
(* A transaction has committed but the log has not been applied yet. *).

Module Log.
  Definition logentry := (addr * valu)%type.
  Definition log := nat -> logentry.

  (* Actually replay a log to implement redo in a memory. *)
  Fixpoint replay (l : log) (len : nat) (m : mem) : mem :=
    match len with
    | O => m
    | S len' =>
      let (a, v) := l len' in
      upd (replay l len' m) a v
    end.

  (* Check that a log is well-formed in memory. *)
  Fixpoint validLog xp (l : log) (len : nat) : Prop :=
    match len with
    | O => True
    | S len' =>
      let (a, v) := l len' in
      DataStart xp <= a < DataStart xp + DataLen xp
      /\ validLog xp l len'
    end.

  Definition logentry_ptsto xp (e : logentry) idx :=
    let (a, v) := e in
    ((LogStart xp + idx*2) |-> a  :: (LogStart xp + idx*2 + 1) |-> v :: nil)%pred.

  Fixpoint logentry_ptsto_len xp l len :=
    match len with
    | O => nil
    | S len' =>
      logentry_ptsto xp (l len') len' ++ logentry_ptsto_len xp l len'
    end%pred.

  Fixpoint logentry_ptsto_lenskip xp l len skipidx :=
    match len with
    | O => nil
    | S len' =>
      if eq_nat_dec len' skipidx then
        logentry_ptsto_lenskip xp l len' skipidx
      else
        logentry_ptsto xp (l len') len' ++
        logentry_ptsto_lenskip xp l len' skipidx
    end%pred.

  Theorem logentry_split : forall xp l len pos,
    pos < len
    -> stars (logentry_ptsto_len xp l len) <==>
       stars ((LogStart xp + pos*2) |-> (fst (l pos)) ::
              (LogStart xp + pos*2 + 1) |-> (snd (l pos)) ::
              logentry_ptsto_lenskip xp l len pos).
  Admitted.

  Definition logupd (l : log) (p : nat) (e : logentry) : log :=
    fun p' => if eq_nat_dec p' p then e else l p'.

  Lemma logupd_eq: forall l p e p',
    p' = p
    -> logupd l p e p' = e.
  Proof.
    unfold logupd; intros; case_eq (eq_nat_dec p' p); congruence.
  Qed.

  Lemma logupd_ne: forall l p e p',
    p' <> p
    -> logupd l p e p' = l p'.
  Proof.
    unfold logupd; intros; case_eq (eq_nat_dec p' p); congruence.
  Qed.

  Theorem logentry_merge : forall xp l len pos a v,
    pos < len
    -> stars (logentry_ptsto_len xp (logupd l pos (a, v)) len) <==>
       stars ((LogStart xp + pos*2) |-> a ::
              (LogStart xp + pos*2 + 1) |-> v ::
              logentry_ptsto_lenskip xp l len pos).
  Admitted.

  Definition data_rep old : pred :=
    diskIs old.

  Definition log_entries xp (l : log) : pred :=
    stars (logentry_ptsto_len xp l (LogLen xp)).

  Definition log_len xp len : pred :=
    ((LogLength xp) |-> len)%pred.

  Definition log_rep xp len l : pred :=
     (log_len xp len
      * [[ len <= LogLen xp ]]
      * [[ validLog xp l len ]]
      * log_entries xp l)%pred.

  Definition cur_rep xp (old : mem) len (l : log) (cur : mem) : pred :=
    [[ forall a, DataStart xp <= a < DataStart xp + DataLen xp
       -> cur a = replay l len old a ]]%pred.

  Definition rep xp (st : logstate) :=
    match st with
      | NoTransaction m =>
        (LogCommit xp) |-> 0
      * (exists len, log_len xp len)
      * (exists log, log_entries xp log)
      * data_rep m

      | ActiveTxn old cur =>
        (LogCommit xp) |-> 0
      * exists len log, log_rep xp len log
      * data_rep old
      * cur_rep xp old len log cur

      | CommittedTxn cur =>
        (LogCommit xp) |-> 1
      * exists len log, log_rep xp len log
      * exists old, data_rep old
      * cur_rep xp old len log cur
    end%pred.

  Ltac log_unfold := unfold rep, data_rep, cur_rep, log_rep, log_len.
(*
  Opaque log_entries.
*)
  Hint Extern 1 (okToUnify (log_entries _ _) (log_entries _ _)) => constructor : okToUnify.

  Definition init xp rx := (LogCommit xp) <-- 0 ;; rx tt.

  Theorem init_ok : forall xp rx rec,
    {{ exists old F l len com, F
     * data_rep old
     * log_entries xp l
     * log_len xp len
     * (LogCommit xp) |-> com
     * [[ {{ rep xp (NoTransaction old) * F }} rx tt >> rec ]]
     * [[ {{ rep xp (NoTransaction old) * F
          \/ data_rep old
             * log_entries xp l
             * log_len xp len
             * (LogCommit xp) |-> com
             * F }} rec >> rec ]]
    }} init xp rx >> rec.
  Proof.
    unfold init; log_unfold.
    hoare.
  Qed.

  Definition begin xp rx := (LogLength xp) <-- 0 ;; rx tt.

  Theorem begin_ok : forall xp rx rec,
    {{ exists m F, rep xp (NoTransaction m) * F
     * [[{{ rep xp (ActiveTxn m m) * F }} rx tt >> rec]]
     * [[{{ rep xp (NoTransaction m) * F }} rec >> rec]]
    }} begin xp rx >> rec.
  Proof.
    unfold begin; log_unfold.
    hoare.
  Qed.

(*
  Lemma log_entries_truncate:
    forall xp l,
    log_entries xp l ==> log_entries xp nil.
  Admitted.
  Hint Resolve log_entries_truncate : imply.
*)

  Definition abort xp rx := (LogLength xp) <-- 0 ;; rx tt.

  Theorem abort_ok : forall xp rx rec,
    {{ exists m1 m2 F, rep xp (ActiveTxn m1 m2) * F
     * [[{{ rep xp (NoTransaction m1) * F }} rx tt >> rec]]
     * [[{{ rep xp (NoTransaction m1) * F }} rec >> rec]]
    }} abort xp rx >> rec.
  Proof.
    unfold abort; log_unfold.
    hoare.
  Qed.

  Definition write xp a v rx :=
    len <- !(LogLength xp);
    If (le_lt_dec (LogLen xp) len) {
      rx false
    } else {
      (LogStart xp + len*2) <-- a;;
      (LogStart xp + len*2 + 1) <-- v;;
      (LogLength xp) <-- (S len);;
      rx true
    }.

  Theorem write_ok : forall xp a v rx rec,
    {{ exists m1 m2 F, rep xp (ActiveTxn m1 m2) * F
     * [[ indomain a m2 ]]
     * [[ {{ rep xp (ActiveTxn m1 (upd m2 a v)) * F }} rx true >> rec ]]
     * [[ {{ rep xp (ActiveTxn m1 m2) * F }} rx false >> rec ]]
     * [[ {{ exists m', rep xp (ActiveTxn m1 m') * F }} rec >> rec ]]
    }} write xp a v rx >> rec.
  Proof.
    unfold write; log_unfold.
    step.
    step.
    step.
    (* XXX need to fish out the right ptsto from "log_entries xp l".. *)
    eapply pimpl_ok; eauto with prog.
    unfold log_entries.
    norm.

    (* Start fishing out ptsto out of log_entries.. *)
    Focus 1.
    delay_one.
    delay_one.

    (* Try to apply logentry_split to log_entries at the head of stars on the left *)
    eapply pimpl_trans; [eapply piff_star_r|].
    apply piff_comm.
    eapply piff_trans; [apply stars_prepend|].
    eapply piff_trans; [eapply piff_star_r|].
    apply logentry_split.

    (* XXX don't want to tell Coq that the existential variable is "v0" yet.. *)
    Focus 2.
    eapply piff_trans; [eapply piff_star_r|].
    eapply piff_trans; [apply stars_prepend|].
    eapply piff_trans; [eapply piff_star_l|].
    eapply piff_trans; [apply stars_prepend|].
    apply flatten_star'.
    apply flatten_default'.
    apply flatten_default'.
    apply flatten_star'.
    apply flatten_default'.
    apply piff_refl.
    apply flatten_star'.
    apply piff_refl.
    apply piff_refl.

    (* XXX still don't want to tell Coq that this is "v0" yet.. *)
    Focus 2.
    simpl.
    eapply cancel_one.
    apply PickFirst.
    apply eq_refl.  (* XXX okToUnify *)

    repeat delay_one.
    apply finish_frame.

    (* Finally, can solve (v0 < length l) *)
    auto.
    (* Done fishing out ptsto out of log_entries.. *)

    intuition eauto; unfold stars; simpl.
    step.
    step.
    step.

    (* Merge ptsto back into log_entries.. *)
    Focus 1.
    eapply pimpl_trans.
    apply flatten_star'. apply flatten_emp'.
    apply flatten_star'.
    (* Re-order the addr and valu [ptsto] preds here for logentry_merge later..
     * Easier to do here, for now.
     *)
    eapply piff_trans; [apply sep_star_assoc|].
    eapply piff_trans; [apply piff_star_l|].
    eapply piff_trans; [apply sep_star_comm|].
    apply flatten_star'.
    apply flatten_default'.
    apply flatten_default'.
    apply flatten_star'. apply flatten_emp'.
    apply piff_refl.
    apply piff_refl.

    simpl.
    eapply pimpl_trans.
    apply logentry_merge.
    auto.  (* v0 < LogLen xp *)
    unfold log_entries. apply pimpl_star_emp.
    (* Done merging ptsto back into log_entries *)

    rewrite logupd_eq; auto.
    (* XXX [indomain a m0] doesn't quite tell us [a] is in range, because we don't
     * know what the domain of [m0] is; all we know is that it seems to have the
     * same domain as [m] due to [m0 a = replay l v0 m a], and nothing else is
     * known about [m]..
     *)
  Abort.

  Definition apply xp rx :=
    len <- !(LogLength xp);
    For i < len
      Ghost cur
      Loopvar _ <- tt
      Continuation lrx
      Invariant
        exists old len log F, F
        * (LogCommit xp) |-> 1
        * data_rep old
        * log_rep xp len log
        * cur_rep xp old len log cur
        * cur_rep xp old i log old
      OnCrash
        (exists F, rep xp (NoTransaction cur) * F) \/
        (exists F, rep xp (CommittedTxn cur) * F)
      Begin
      a <- !(LogStart xp + i*2);
      v <- !(LogStart xp + i*2 + 1);
      a <-- v;;
      lrx tt
    Rof;;
    (LogCommit xp) <-- 0;;
    rx tt.

(*
  Lemma validLog_irrel : forall xp a len m1 m2,
    validLog xp a len m1
    -> (forall a', a <= a' < a + len*2
      -> m1 a' = m2 a')
    -> validLog xp a len m2.
  Proof.
    induction len; simpl; intuition eauto;
      try match goal with
            | [ H : _ |- _ ] => rewrite <- H by omega; solve [ auto ]
            | [ H : _ |- _ ] => eapply H; intuition eauto
          end.
  Qed.

  Lemma validLog_data : forall xp m len a x1,
    m < len
    -> validLog xp a len x1
    -> DataStart xp <= x1 (a + m * 2) < DataStart xp + DataLen xp.
  Proof.
    induction len; simpl; intros.
    intuition.
    destruct H0.
    destruct (eq_nat_dec m len); subst; auto.
  Qed.

  Lemma upd_same : forall m1 m2 a1 a2 v1 v2 a',
    a1 = a2
    -> v1 = v2
    -> (a' <> a1 -> m1 a' = m2 a')
    -> upd m1 a1 v1 a' = upd m2 a2 v2 a'.
  Proof.
    intros; subst; unfold upd; destruct (eq_nat_dec a' a2); auto.
  Qed.

  Hint Resolve upd_same.

  Lemma replay_irrel : forall xp a',
    DataStart xp <= a' < DataStart xp + DataLen xp
    -> forall a len m1 m2,
      (forall a', a <= a' < a + len*2
        -> m1 a' = m2 a')
      -> m1 a' = m2 a'
      -> replay a len m1 a' = replay a len m2 a'.
  Proof.
    induction len; simpl; intuition eauto.
    apply upd_same; eauto.
  Qed.

  Hint Rewrite plus_0_r.

  Lemma replay_redo : forall a a' len m1 m2,
    (forall a'', a <= a'' < a + len*2
      -> m1 a'' = m2 a'')
    -> (m1 a' <> m2 a'
      -> exists k, k < len
        /\ m1 (a + k*2) = a'
        /\ m2 (a + k*2) = a')
    -> ~(a <= a' < a + len*2)
    -> replay a len m1 a' = replay a len m2 a'.
  Proof.
    induction len; simpl; intuition.
    destruct (eq_nat_dec (m1 a') (m2 a')); auto.
    apply H0 in n.
    destruct n; intuition omega.

    apply upd_same; eauto; intros.
    apply IHlen; eauto; intros.
    apply H0 in H3.
    destruct H3; intuition.
    destruct (eq_nat_dec x len); subst; eauto.
    2: exists x; eauto.
    tauto.
  Qed.
*)

  Theorem apply_ok : forall xp rx rec,
    {{ exists m F, rep xp (CommittedTxn m) * F
     * [[ {{ rep xp (NoTransaction m) * F }} rx tt >> rec ]]
     * [[ {{ rep xp (NoTransaction m) * F
          \/ rep xp (CommittedTxn m) * F }} rec >> rec ]]
    }} apply xp rx >> rec.
  Proof.
    unfold apply; log_unfold.
    step.
    step.
    norm; [|intuition].
    apply stars_or_right.
    unfold stars; simpl; norm.
    cancel.
    intuition.
    (* XXX have to do "cancel" before "intuition", otherwise intuition makes up a "min".. *)
    step.
    (* XXX log contents.. *)
  Admitted.

  Hint Extern 1 ({{_}} progseq (apply _) _ >> _) => apply apply_ok : prog.

(*
  Theorem apply_ok : forall xp m, {{rep xp (CommittedTxn m)}} (apply xp)
    {{r, rep xp (NoTransaction m)
      \/ ([r = Crashed] /\ rep xp (CommittedTxn m))}}.
  Proof.
    hoare.

    - eauto 10.
    - eauto 10.
    - eauto 12.
    - eauto 12.
    - eauto 12.
    - assert (DataStart xp <= x1 (LogStart xp + m0 * 2) < DataStart xp + DataLen xp) by eauto using validLog_data.
      left; exists tt; intuition eauto.
      eexists; intuition eauto.
      + rewrite H0 by auto.
        apply replay_redo.
        * pred.
        * destruct (eq_nat_dec a (x1 (LogStart xp + m0 * 2))); subst; eauto; pred.
          eexists; intuition eauto; pred.
        * pred.
          disjoint xp.
      + pred.
      + pred.
      + eapply validLog_irrel; eauto; pred.
      + apply upd_same; pred.
        rewrite H9 by auto.
        apply replay_redo.
        * pred.
        * destruct (eq_nat_dec a (x1 (LogStart xp + m0 * 2))); subst; eauto; pred.
        * pred.
          disjoint xp.
    - eauto 12.
    - left; intuition.
      pred.
      firstorder.
  Qed.
*)

  Definition commit xp rx :=
    (LogCommit xp) <-- 1;;
    apply xp;;
    rx tt.

  Theorem commit_ok : forall xp rx rec,
    {{ exists m1 m2 F, rep xp (ActiveTxn m1 m2) * F
     * [[ {{ rep xp (NoTransaction m2) * F }} rx tt >> rec ]]
     * [[ {{ rep xp (NoTransaction m2) * F
          \/ rep xp (ActiveTxn m1 m2) * F
          \/ rep xp (CommittedTxn m2) * F }} rec >> rec ]]
    }} commit xp rx >> rec.
  Proof.
    unfold commit; log_unfold.
    step.
    step.

    (* XXX need to log_unfold again, because these guys came from apply_ok's theorem *)
    log_unfold.
    norm. cancel. intuition eauto.

    (* XXX need to log_unfold again *)
    log_unfold.
    step.
    norm. apply stars_or_right. apply stars_or_right. unfold stars; simpl.
    norm. cancel.
    intuition eauto. intuition eauto.

    step.
    norm. apply stars_or_right. apply stars_or_right. unfold stars; simpl.
    norm. cancel.
    intuition eauto. intuition eauto.

    norm. apply stars_or_right. apply stars_or_left. unfold stars; simpl.
    norm. cancel.
    intuition eauto. intuition eauto.
  Qed.

  Definition recover xp rx :=
    com <- !(LogCommit xp);
    If (eq_nat_dec com 1) {
      apply xp rx
    } else {
      rx tt
    }.

  Theorem recover_ok : forall xp rx rec,
    {{ exists m F, (rep xp (NoTransaction m) * F \/
                    (exists m', rep xp (ActiveTxn m m') * F) \/
                    rep xp (CommittedTxn m) * F)
     * [[ {{ rep xp (NoTransaction m) * F }} rx tt >> rec ]]
     * [[ {{ rep xp (NoTransaction m) * F
          \/ rep xp (CommittedTxn m) * F }} rec >> rec ]]
    }} recover xp rx >> rec.
  Proof.
    unfold recover; log_unfold.
    step.
    norm.

    hoare.
    - left. sep_imply. normalize_stars_r. cancel.
    - left. sep_imply. normalize_stars_r. cancel.
    - left. sep_imply. normalize_stars_r. cancel.
    - sep_imply. normalize_stars_l. normalize_stars_r.
      assert (dataIs xp x x1 x2 ==> dataIs xp x x 0) by eauto using dataIs_truncate.
      cancel.
    - (* XXX something is wrong.. *)
  Abort.

  Definition read xp a rx :=
    len <- !(LogLength xp);
    v <- !a;

    v <- For i < len
      Loopvar v <- v
      Continuation lrx
      Invariant
        [True]
(*
       ([DataStart xp <= a < DataStart xp + DataLen xp]
        /\ (foral a, [DataStart xp <= a < DataStart xp + DataLen xp]
          --> a |-> fst old_cur a)
        /\ (LogCommit xp) |-> 0
        /\ (LogLength xp) |-> len
          /\ [len <= LogLen xp]
          /\ exists m, diskIs m
            /\ [validLog xp (LogStart xp) len m]
            /\ [forall a, DataStart xp <= a < DataStart xp + DataLen xp
              -> snd old_cur a = replay (LogStart xp) len m a]
            /\ [v = replay (LogStart xp) i m a])
*)
      OnCrash
        [True]
(* rep xp (ActiveTxn old_cur) *)
      Begin
      a' <- !(LogStart xp + i*2);
      If (eq_nat_dec a' a) {
        v <- !(LogStart xp + i*2 + 1);
        lrx v
      } else {
        lrx v
      }
    Rof;

    rx v.

  Theorem read_ok : forall xp a rx rec,
    {{ exists m1 m2 v F F', rep xp (ActiveTxn m1 m2) * F
    /\ [(a |-> v * F')%pred m2]
    /\ [{{ [(a |-> v * F')%pred m2] /\ rep xp (ActiveTxn m1 m2) * F }} rx v >> rec]
    /\ [{{ [(a |-> v * F')%pred m2] /\ rep xp (ActiveTxn m1 m2) * F }} rec >> rec]
    }} read xp a rx >> rec.
  Proof.
    unfold read.
    hoare.
(*
    - eauto 7.
    - eauto 20.
    - eauto 20.
    - eauto 20.

    - left; eexists; intuition.
      eexists; pred.

    - eauto 20.

    - left; eexists; intuition.
      eexists; pred.

    - eauto 10.

    - rewrite H6; pred.
*)
  Abort.

End Log.

(* Ideally, would detect log overflow in this wrapper, and call the rx continuation
 * with (None) for overflow, and (Some v) for successful commit..
 *)
Definition txn_wrap (T : Type) xp (p : (T -> prog) -> prog) (rx : T -> prog) :=
  Log.begin xp;;
  v <- p;
  Log.commit xp;;
  rx v.

Theorem txn_wrap_ok : forall T xp (p : (T -> prog) -> prog) rx rec,
  {{ exists m1 m2 v F, Log.rep xp (NoTransaction m1) * F
  /\ [forall prx,
      {{ exists F', Log.rep xp (ActiveTxn m1 m1) * F'
      /\ [{{ Log.rep xp (ActiveTxn m1 m2) * F' }} prx v >> Log.recover xp rec]
      }} p prx >> Log.recover xp rec]
  /\ [{{ Log.rep xp (NoTransaction m2) * F }} rx v >> Log.recover xp rec]
  /\ [{{ Log.rep xp (NoTransaction m1) * F
      \/ Log.rep xp (NoTransaction m2) * F
      }} rec tt >> Log.recover xp rec]
  }} txn_wrap xp p rx >> Log.recover xp rec.
Proof.
  unfold txn_wrap.
  hoare.
Abort.



(*
Definition wrappable (R:Set) (p:prog R) (fn:mem->mem) := forall m0 m,
  {{Log.rep the_xp (ActiveTxn (m0, m))}}
  p
  {{r, Log.rep the_xp (ActiveTxn (m0, fn m))
    \/ ([r = Crashed] /\ exists m', Log.rep the_xp (ActiveTxn (m0, m')))}}.

Definition txn_wrap (p:prog unit) (fn:mem->mem) (wr: wrappable p fn) := $(unit:
  Call1 (Log.begin_ok the_xp);;
  Call2 (wr);;
  Call2 (Log.commit_ok the_xp)
).

Theorem txn_wrap_ok_norecover:
  forall (p:prog unit) (fn:mem->mem) (wrappable_p: wrappable p fn) m,
  {{Log.rep the_xp (NoTransaction m)}}
  (txn_wrap wrappable_p)
  {{r, Log.rep the_xp (NoTransaction (fn m))
    \/ ([r = Crashed] /\ (Log.rep the_xp (NoTransaction m) \/
                          (exists m', Log.rep the_xp (ActiveTxn (m, m'))) \/
                          Log.rep the_xp (CommittedTxn (fn m))))}}.
Proof.
  hoare.
  - destruct (H1 m); clear H1; pred.
  - destruct (H m); clear H; pred.
    destruct (H0 m m); clear H0; pred.
    destruct (H m); clear H; pred.
  - destruct (H m); clear H; pred.
    destruct (H0 m (fn m)); clear H0; pred.
    destruct (H m); clear H; pred.
    destruct (H0 m m); clear H0; pred.
    destruct (H m); clear H; pred.
Qed.

Theorem txn_wrap_ok:
  forall (p:prog unit) (fn:mem->mem) (wrappable_p: wrappable p fn) m,
  {{Log.rep the_xp (NoTransaction m)}}
  (txn_wrap wrappable_p)
  {{r, Log.rep the_xp (NoTransaction (fn m))}}
  {{Log.rep the_xp (NoTransaction m) \/
    Log.rep the_xp (NoTransaction (fn m))}}.
Proof.
  intros.
  eapply RCConseq.
  instantiate (1:=(fun r : outcome unit =>
                     Log.rep the_xp (NoTransaction m) \/
                     Log.rep the_xp (NoTransaction (fn m)) \/
                     ([r = Crashed] /\ Log.rep the_xp (CommittedTxn m)) \/
                     ([r = Crashed] /\ Log.rep the_xp (CommittedTxn (fn m)))
                  )%pred (Halted tt)).
  instantiate (1:=fun r : unit =>
                  (fun res : outcome unit =>
                     match res with
                     | Halted _ => Log.rep the_xp (NoTransaction (fn m))
                     | Crashed => Log.rep the_xp (NoTransaction m) \/
                                  Log.rep the_xp (NoTransaction (fn m)) \/
                                  (exists m', Log.rep the_xp (ActiveTxn (m, m'))) \/
                                  Log.rep the_xp (CommittedTxn (fn m))
                     end
                   )%pred (Halted r)).
  instantiate (1:=(Log.rep the_xp (NoTransaction m))%pred).
  apply RCbase.

  (* corr 1: hoare triple for write_two_blocks *)
  eapply Conseq.
  apply txn_wrap_ok_norecover.
  pred.
  pred; destruct r; pred.

  (* corr 2: hoare triple for the first time recover runs *)
  constructor.  (* CPreOr *)
  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  constructor.  (* CPreOr *)
  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  constructor.  (* CPreOr *)
  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  (* corr 3: hoare triple for repeated recover runs *)
  constructor.  (* CPreOr *)
  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  constructor.  (* CPreOr *)
  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  constructor.  (* CPreOr *)
  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  eapply Conseq.
  apply Log.recover_ok.
  pred.
  pred.

  (* prove implicications from the original RCConseq *)
  pred.
  pred.
  pred.
Qed.



Definition write_two_blocks a1 a2 v1 v2 := $((mem*mem):
  Call1 (Log.write_ok the_xp a1 v1);;
  Call1 (Log.write_ok the_xp a2 v2)
(*
  Call2 (fun (z:unit) => Log.write_ok the_xp a2 v2)
*)
).

Theorem write_two_blocks_wrappable a1 a2 v1 v2
  (A1OK: DataStart the_xp <= a1 < DataStart the_xp + DataLen the_xp)
  (A2OK: DataStart the_xp <= a2 < DataStart the_xp + DataLen the_xp):
  wrappable (write_two_blocks a1 a2 v1 v2) (fun m => upd (upd m a1 v1) a2 v2).
Proof.
  unfold wrappable; intros.
  hoare_ghost (m0, m).
  - destruct (H5 (m0, m)); clear H5; pred.
  - destruct (H3 (m0, (upd m a1 v1))); clear H3; pred.
    destruct (H3 (m0, m)); clear H3; pred.
Qed.

Parameter a1 : nat.
Parameter a2 : nat.
Parameter v1 : nat.
Parameter v2 : nat.
Parameter A1OK: DataStart the_xp <= a1 < DataStart the_xp + DataLen the_xp.
Parameter A2OK: DataStart the_xp <= a2 < DataStart the_xp + DataLen the_xp.


Check (txn_wrap (write_two_blocks_wrappable v1 v2 A1OK A2OK)).
Check (txn_wrap_ok (write_two_blocks_wrappable v1 v2 A1OK A2OK)).



Definition wrappable_nd (R:Set) (p:prog R) (ok:pred) := forall m,
  {{Log.rep the_xp (ActiveTxn (m, m))}}
  p
  {{r, (exists! m', Log.rep the_xp (ActiveTxn (m, m')) /\ [ok m'])
    \/ ([r = Crashed] /\ exists m', Log.rep the_xp (ActiveTxn (m, m')))}}.

Definition txn_wrap_nd (p:prog unit) (ok:pred) (wr: wrappable_nd p ok) (m: mem) := $(unit:
  Call0 (Log.begin_ok the_xp m);;
  Call0 (wr m);;
  Call1 (fun m' => Log.commit_ok the_xp m m')
).

Theorem txn_wrap_nd_ok_norecover:
  forall (p:prog unit) (ok:pred) (wr: wrappable_nd p ok) m,
  {{Log.rep the_xp (NoTransaction m)}}
  (txn_wrap_nd wr m)
  {{r, (exists m', Log.rep the_xp (NoTransaction m') /\ [ok m'])
    \/ ([r = Crashed] (* /\ (Log.rep the_xp (NoTransaction m) \/
                          (exists m', Log.rep the_xp (ActiveTxn (m, m'))) \/
                          (exists m', Log.rep the_xp (CommittedTxn m') /\ [ok m'])) *) )}}.
Proof.
  hoare.
  destruct (H x2); clear H; pred.
  (* XXX something is still broken.. *)



  - destruct (H1 m); clear H1; pred.
  - destruct (H1 m); clear H1; pred.
    destruct (H m); clear H; pred.
    destruct (H1 m); clear H1; pred.
  - destruct (H1 m); clear H1; pred.
    destruct (H m); clear H; pred.
    + destruct (H m); clear H; pred.
    + (* we have our non-deterministic mem: x4 *)
      destruct (H0 m x4); clear H0; pred.

      destruct (H1 m); clear H1; pred.
      destruct (H0 m); clear H0; pred.
      destruct (H0 m); clear H0; pred.
      erewrite H2. apply H5. 
      erewrite H8 in H5.  apply H5.  appl
      (* XXX so close but something is broken..
       * we need to prove:
       *   Log.rep the_xp (ActiveTxn (m, x4)) m1
       * but we have:
       *   Log.rep the_xp (ActiveTxn (m, x7)) m1
       * where x7 and x4 are two possibly-different mem's, both of which satisfy ok.
       *
       * seems like the pre-/post-conditions of wr get copied to several places,
       * and when we destruct them, we end up with two possibly-different mem's,
       * since there's no constraint that they be the same..
       *)
Aborted.
*)
