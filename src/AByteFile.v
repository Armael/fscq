Require Export BFile.
Require Export Bytes.
Require Export Inode.
Require Export Word.
Require Export AsyncDisk.
Require Export String.
Require Export Rec.
Require Export Log.
Require Export Arith.
Require Export Prog.
Require Import BasicProg.
Require Export List.
Require Export Pred PredCrash ListPred.
Require Export Mem.
Require Export Hoare.
Require Export SepAuto.


Require Import Arith.
Require Import Pred PredCrash.
Require Import Word.
Require Import Prog.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.
Require Import Omega.
Require Import Log.
Require Import Array.
Require Import List ListUtils.
Require Import Bool.
Require Import Eqdep_dec.
Require Import Setoid.
Require Import Rec.
Require Import FunctionalExtensionality.
Require Import NArith.
Require Import WordAuto.
Require Import RecArrayUtils LogRecArray.
Require Import GenSepN.
Require Import Balloc.
Require Import ListPred.
Require Import FSLayout.
Require Import AsyncDisk.
Require Import Inode.
Require Import GenSepAuto.
Require Import DiskSet.






Set Implicit Arguments.

Module ABYTEFILE.

Check BFILE.rep.

Variable AT : Type.
Variable AEQ : EqDec AT.
Variable V : Type.
Variable block_size : addr.



Record byte_file := mk_byte_file {
  BFData : list valuset;
  BFAttr : INODE.iattr
}.

Definition modulo (n m: nat) : nat := n - ((n / m) * m)%nat.

Definition valu_to_list: valu -> list byte.
Proof. Admitted.

Definition get_block_size: valu -> nat.
Proof. Admitted.


Fixpoint get_sublist {A:Type}(l: list A) (off len: nat) : list A :=
  match off with
  | O => match len with 
          | O => nil
          | S len' => match l with
                      | nil => nil
                      | b::l' => b::(get_sublist l' O len')
                      end
          end
  | S off'=> match l with
              | nil => nil
              | b::l' => (get_sublist l' off' len)
              end
  end.

  
(*Ugly but at least compiling*)

Definition read_bytes {T} lxp ixp inum (off len:nat) fms rx : prog T :=
If (lt_dec 0 len)                        (* if read length > 0 *)
{                    
  let^ (fms, flen) <- BFILE.getlen lxp ixp inum fms;          (* get file length *)
  If (lt_dec off flen)                   (* if offset is inside file *)
  {                    
    If(le_dec (off+len) flen)     (* if you can read the whole length *)
    {                           
      let^ (fms, block0) <- BFILE.read lxp ixp inum 0 fms;        (* get block 0*)
      let block_size := (get_block_size block0) in            (* get block size *)
      let block_off := (off / block_size) in              (* calculate block offset *)
      let byte_off := (modulo off block_size) in          (* calculate byte offset *)
      let^ (fms, first_block) <- BFILE.read lxp ixp inum block_off fms;   (* get first block *)
      If(le_dec (byte_off + len) block_size)             (* if whole data is in this block *)
      {
        let data := (get_sublist                          (* read the data and return as list byte *)
        (valu_to_list first_block) byte_off len) in
        rx ^(fms, data)
      } 
      else                                            (* If data is in more than one block *)
      {     
        let data_init := (get_sublist                     (* read as much as you can from this block *)
        (valu_to_list first_block) byte_off         
         (block_size - byte_off)) in
        let block_off := (block_off +1) in                      (* offset of remaining part *)
        let len_remain := (len - (block_size - byte_off)) in  (* length of remaining part *)
        let num_of_full_blocks := (len_remain / block_size) in (* number of full blocks in length *)
        
        (*for loop for reading those full blocks *)
        let^ (data) <- (ForN_ (fun i =>
          (pair_args_helper (fun data (_:unit) => (fun lrx => 
          
          let^ (fms, block) <- BFILE.read lxp ixp inum (block_off + i) fms; (* get i'th block *)
          lrx ^(data++(get_sublist (valu_to_list block) 0 block_size))%list (* append its contents *)
          
          )))) 0 num_of_full_blocks
        (fun _:nat => (fun _ => (fun _ => (fun _ => (fun _ => True)%pred)))) (* trivial invariant *)
        (fun _:nat => (fun _ => (fun _ => True)%pred))) ^(nil);             (* trivial crashpred *)
        
        let off_final := (block_off + num_of_full_blocks * block_size) in (* offset of final block *)
        let len_final := (len_remain - num_of_full_blocks * block_size) in (* final remaining length *)
        let^ (fms, last_block) <- BFILE.read lxp ixp inum off_final fms;   (* get final block *)
        let data_final := (get_sublist (valu_to_list last_block) 0 len_final) in (* get final block data *)
        rx ^(fms, data_init++data++data_final)%list                  (* append everything and return *)
      }
    } 
    else                                              (* If you cannot read the whole length *)
    {    
      let len:= (flen - off) in                               (* set length to remaining length of file *)
      let^ (fms, block0) <- BFILE.read lxp ixp inum 0 fms;    (* get block 0 *)
      let block_size := (get_block_size block0) in (* get block size *)
      let block_off := (off / block_size) in              (* calculate block offset *)
      let byte_off := (modulo off block_size) in          (* calculate byte offset *)
      let^ (fms, first_block) <- BFILE.read lxp ixp inum off fms;   (* get first block *)
      If(le_dec (byte_off + len) block_size)             (* if whole data is in this block *)
      {
        let data := (get_sublist                          (* read the data and return as list byte *)
        (valu_to_list first_block) byte_off len) in
        rx ^(fms, data)
      } 
      else                                              (* If data is in more than one block *)
      {   
        let data_init := (get_sublist                     (* read as much as you can from this block *)
        (valu_to_list first_block) byte_off  
         (block_size - byte_off)) in
        let block_off := (block_off +1) in  (* offset of remaining part *)
        let len_remain := (len - (block_size - byte_off)) in  (* length of remaining part *)
        let num_of_full_blocks := (len_remain / block_size) in (* number of full blocks in length *)
        
        
        (*for loop for reading those full blocks *)
        let^ (data) <- (ForN_ (fun i =>
          (pair_args_helper (fun data (_:unit) => (fun lrx => 
          
          let^ (fms, block) <- BFILE.read lxp ixp inum (block_off + i) fms; (* get i'th block *)
          lrx ^(data++(get_sublist (valu_to_list block) 0 block_size))%list (* append its contents *)
          
          )))) 0 num_of_full_blocks
        (fun _:nat => (fun _ => (fun _ => (fun _ => (fun _ => True)%pred)))) (* trivial invariant *)
        (fun _:nat => (fun _ => (fun _ => True)%pred))) ^(nil);             (* trivial crashpred *)

        rx ^(fms, data_init++data)%list                  (* append everything and return *)
      }
     }
  } 
  else                                                 (* if offset is not valid, return nil *)
  {    
    rx ^(fms, nil)
  }
} 
else                                                   (* if read length is not valid, return nil *)
{    
  rx ^(fms, nil)
}.

SearchAbout BFILE.memstate.
SearchAbout GroupLog.GLog.memstate.
SearchAbout MemLog.MLog.memstate.
SearchAbout MemLog.MLog.mstate.
SearchAbout mem.
Locate "[[[".
Print list2nmem.

Theorem read_bytes_ok : forall lxp bxp ixp inum off len ms,
    {< F Fm Fi Fd m0 m flist ilist frees f vs ve,
    PRE:hm
        let block_size := (get_block_size (fst vs)) in
        let block_off := off / block_size in
        let byte_off := modulo off block_size in
        let first_read_length := (block_size - byte_off) in
        let num_of_full_reads := (len - first_read_length) / block_size in
        let last_read_length := len - first_read_length - num_of_full_reads * block_size in
        let file_length := length (BFILE.BFData f) in
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (BFILE.MSLL ms) hm *
           [[[ m ::: (Fm * BFILE.rep bxp ixp flist ilist frees) ]]] *
           [[[ flist ::: (Fi * inum |-> f) ]]] *
           [[[ (BFILE.BFData f) ::: (Fd * block_off |-> vs * ((block_off + num_of_full_reads)|-> ve \/ [[file_length < off + len]]) )]]]*
           [[ off < file_length ]]*
           [[ 0 < len ]]
    POST:hm' RET:^(ms', r)
          let block_size := (get_block_size (fst vs)) in
          let block_off := off / block_size in
          let byte_off := modulo off block_size in
          let first_read_length := (block_size - byte_off) in
          let num_of_full_reads := (len - first_read_length) / block_size in
          let last_read_length := len - first_read_length - num_of_full_reads * block_size in
          let file_length := length (BFILE.BFData f) in
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (BFILE.MSLL ms') hm' *
           [[  
           (*[1]You read correctly*)
           ((off + len <= file_length /\        (*[1.1]You read the full length OR*)
               
               (*[1.1.1]You read the first block correctly AND*)
               (get_sublist r 0 first_read_length = get_sublist (valu_to_list (fst vs)) byte_off first_read_length ) /\ 
               
               (*[1.1.2]You read all middle blocks correctly AND*)
               (forall (i:nat) bl, (num_of_full_reads < i) \/ (*[1.1.2.1]i is out of range OR*)
                  (*[1.1.2.2]i+1'th block you read matches its contents*)
                  ((exists F', (F' * (block_off +1 + i)|-> bl) (list2nmem m)) /\ (*[1.1.2.2.1]Block bl is in the address (block_off +1 + i) AND*)
                  (get_sublist r (first_read_length + i*block_size) block_size (*[1.1.2.2.2]Block bl is in the address (block_off +1 + i)*)
                      = valu_to_list (fst bl)))) /\
               
               (*[1.1.3]You read the last block correctly*)
               (get_sublist r (len - last_read_length) last_read_length 
                  = get_sublist (valu_to_list (fst ve)) 0 last_read_length))
             \/
             
             (file_length < off + len /\ (*[1.2]You read as much as possible*)
             
                (*[1.2.1]You read the first block correctly AND*)
                (get_sublist r 0 first_read_length = get_sublist (valu_to_list (fst vs)) byte_off first_read_length ) /\
                
                (*[1.2.2]You read remaining blocks correctly*)
                (forall (i:nat) bl, ((file_length - off - first_read_length)/block_size < i) \/ (*[1.2.2.1]i is out of range OR*)
                  (*[1.2.2.2]i+1'th block you read matches its contents*)
                  ((exists F', (F' * (block_off +1 + i)|-> bl) (list2nmem m)) /\ (*[1.2.2.2.1]Block bl is in the address (block_off +1 + i) AND*)
                  (get_sublist r (first_read_length + i*block_size) block_size  (*[1.2.2.2.2]Block bl is in the address (block_off +1 + i)*)
                      = valu_to_list (fst bl))))))
              (*[2]Memory contents didn't change*)
              /\ BFILE.MSAlloc ms = BFILE.MSAlloc ms' ]]
    CRASH:hm'  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) (BFILE.MSLL ms') hm'
    >} read_bytes lxp ixp inum off len ms.

End ABYTEFILE.