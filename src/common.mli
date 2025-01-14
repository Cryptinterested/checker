(* Oracle data *)
val oracle_entrypoint : string

(* OPERATIONS ON int *)
val int_zero : Ligo.int

val min_int : Ligo.int -> Ligo.int -> Ligo.int
val max_int : Ligo.int -> Ligo.int -> Ligo.int

val neg_int : Ligo.int -> Ligo.int

val pow_int_nat : Ligo.int -> Ligo.nat -> Ligo.int

val cdiv_int_int : Ligo.int -> Ligo.int -> Ligo.int
val fdiv_int_int : Ligo.int -> Ligo.int -> Ligo.int

val clamp_int : Ligo.int -> Ligo.int -> Ligo.int -> Ligo.int

(* OPERATIONS ON tez *)
val tez_to_mutez : Ligo.tez -> Ligo.int

(* OPERATIONS ON nat *)
val min_nat : Ligo.nat -> Ligo.nat -> Ligo.nat
val max_nat : Ligo.nat -> Ligo.nat -> Ligo.nat

(* RATIOS AND OPERATIONS ON THEM *)
type ratio = {
  num: Ligo.int;
  den: Ligo.int;
}

val make_ratio : Ligo.int -> Ligo.int -> ratio

val zero_ratio : ratio
val one_ratio : ratio

val fraction_to_tez_floor : Ligo.int -> Ligo.int -> Ligo.tez
val fraction_to_nat_floor : Ligo.int -> Ligo.int -> Ligo.nat

(* BEGIN_OCAML *)
val compare_int : Ligo.int -> Ligo.int -> Int.t
val compare_nat : Ligo.nat -> Ligo.nat -> Int.t

val show_ratio : ratio -> string
val pp_ratio : Format.formatter -> ratio -> unit
(* END_OCAML *)
