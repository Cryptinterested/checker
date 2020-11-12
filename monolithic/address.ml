(* ************************************************************************* *)
(*                                Address                                    *)
(* ************************************************************************* *)
type t = int

let show address = Format.sprintf "tz_%d" address
let pp ppf address = Format.fprintf ppf "%s" (show address)

let initial_address = 0
let next = succ

let compare = Stdlib.compare

let of_string s = int_of_string s

