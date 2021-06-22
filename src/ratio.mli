type ratio = {
  num: Ligo.int; (** Numerator. *)
  den: Ligo.int; (** Denominator, > 0 *)
}

(* Construction/deconstruction. *)
val make_ratio: Ligo.int -> Ligo.int -> ratio

(* Predefined values *)
val zero_ratio: ratio
val one_ratio: ratio

(* Conversions to/from other types. *)
val ratio_of_int: Ligo.int -> ratio

val ratio_of_nat: Ligo.nat -> ratio
val fraction_to_nat_floor: Ligo.int -> Ligo.int -> Ligo.nat

val ratio_of_tez: Ligo.tez -> ratio
val fraction_to_tez_floor: Ligo.int -> Ligo.int -> Ligo.tez
val fraction_to_tez_ceil: Ligo.int -> Ligo.int -> Ligo.tez

(* Relational operations. *)
val eq_ratio_ratio: ratio -> ratio -> bool
val lt_ratio_ratio: ratio -> ratio -> bool
val gt_ratio_ratio: ratio -> ratio -> bool
val leq_ratio_ratio: ratio -> ratio -> bool
val geq_ratio_ratio: ratio -> ratio -> bool

(* Other operations *)

(* NOTE: OCaml's polymorphic comparison will NOT return a result consistent
 * with the ordering of rationals we provide here (OCaml's comparison will use
 * lexicographic ordering which is incorrect in this instance). *)
val min_ratio: ratio -> ratio -> ratio
val max_ratio: ratio -> ratio -> ratio

(* Basic unary operations. *)
val neg_ratio: ratio -> ratio

(* Basic binary operations. *)
val add_ratio: ratio -> ratio -> ratio
val sub_ratio: ratio -> ratio -> ratio
val mul_ratio: ratio -> ratio -> ratio
val div_ratio: ratio -> ratio -> ratio

val qexp: ratio -> ratio

(* BEGIN_OCAML *)
val pp_ratio: Format.formatter -> ratio -> unit
val show_ratio: ratio -> string

val sign_ratio: ratio -> int

val clamp_ratio: ratio -> ratio -> ratio -> ratio
(* END_OCAML *)
