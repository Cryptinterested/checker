open Kit
open Tok
open FixedPoint
open Parameters
open Common

(** Representation of a burrow contract. *)
type burrow

val show_burrow : burrow -> string
val pp_burrow : Format.formatter -> burrow -> unit

(* Burrow API *)
val burrow_address : burrow -> Ligo.address
val burrow_collateral_at_auction : burrow -> tok

(** Computes the total amount of collateral associated with a burrow. This
  * includes the collateral, collateral_at_auction, and the creation_deposit if
  * the burrow is active. *)
val burrow_total_associated_tok : burrow -> tok

(** Check whether a burrow is overburrowed. A burrow is overburrowed if
  *
  *   collateral < fminting * kit_outstanding * minting_price
  *
  * The quantity collateral / (fminting * minting_price) we call the burrowing
  * limit (normally kit_outstanding <= burrowing_limit).
*)
val burrow_is_overburrowed : parameters -> burrow -> bool

(** The maximum number of kit, given the current collateral in the burrow. *)
val burrow_max_mintable_kit : parameters -> burrow -> kit

(** Check whether a burrow can be marked for liquidation. A burrow can be
  * marked for liquidation if:
  *
  *   collateral < fliquidation * kit_outstanding * liquidation_price
  *
  * The quantity collateral / (fliquidation * liquidation_price) we call the
  * liquidation limit. Note that for this check we optimistically take into
  * account the expected kit from pending auctions (using the current minting
  * price) when computing the outstanding kit. Note that only active burrows
  * can be liquidated; inactive ones are dormant, until either all pending
  * auctions finish or if their creation deposit is restored. *)
val burrow_is_liquidatable : parameters -> burrow -> bool

(** Check whether the return of a slice to its burrow (cancellation) is
  * warranted. For the cancellation to be warranted, it must be the case that
  * after returning the slice to the burrow, the burrow is optimistically
  * non-overburrowed (i.e., if all remaining collateral at auction sells at the
  * current price but with penalties paid, the burrow becomes underburrowed):
  *
  *   collateral + slice >= fminting * (outstanding - compute_expected_kit (collateral_at_auction - slice)) * minting_price
  *
  * Note that only active burrows can be liquidated; inactive ones are dormant,
  * until either all pending auctions finish or if their creation deposit is
  * restored. *)
val burrow_is_cancellation_warranted : parameters -> burrow -> tok -> bool

(** Perform housekeeping tasks on the burrow. This includes:
  * - Updating the outstanding kit to reflect accrued burrow fees and imbalance adjustment.
  * - Update the last observed adjustment index
  * - Update the last observed timestamp.
*)
val burrow_touch : parameters -> burrow -> burrow

(** Deposit the kit earnings from the liquidation of a slice into the burrow
  * (i.e., update the outstanding kit and the collateral at auction). Return
  * the amount of kit repaid, and the amount of excess kit. *)
val burrow_return_kit_from_auction : LiquidationAuctionPrimitiveTypes.liquidation_slice_contents -> kit -> burrow -> burrow * kit * kit

(** Cancel the liquidation of a slice. That is, (a) return the collateral that
  * is part of a liquidation slice back to the burrow and (b) adjust the
  * burrow's pointers to the liquidation queue accordingly (which is a no-op if
  * we are not deleting the youngest or the oldest liquidation slice). *)
val burrow_return_slice_from_auction : LiquidationAuctionPrimitiveTypes.liquidation_slice_contents -> burrow -> burrow

(** Given an amount of collateral (including a creation deposit, not counting
  * towards that collateral), create a burrow with its owner set to the input
  * address. Fail if the collateral given is less than the creation deposit. *)
val burrow_create : parameters -> Ligo.address -> tok -> Ligo.key_hash option -> burrow

(** Add non-negative collateral to a burrow. *)
val burrow_deposit_collateral : parameters -> tok -> burrow -> burrow

(** Withdraw an amount of collateral from the burrow, as long as this will
  * not overburrow it. *)
val burrow_withdraw_collateral : parameters -> tok -> burrow -> burrow

(** Mint a non-negative amount of kit from the burrow, as long as this will
  * not overburrow it *)
val burrow_mint_kit : parameters -> kit -> burrow -> burrow

(** Deposit/burn a non-negative amount of kit to the burrow. Return the amount
  * of kit burned. *)
val burrow_burn_kit : parameters -> kit -> burrow -> burrow * kit

(** Activate a currently inactive burrow. This operation will fail if either
  * the burrow is already active, or if the amount of collateral given is less
  * than the creation deposit. *)
val burrow_activate : parameters -> tok -> burrow -> burrow

(** Deativate a currently active burrow. This operation will fail if the burrow
  * (a) is already inactive, or (b) is overburrowed, or (c) has kit
  * outstanding, or (d) has collateral sent off to auctions. *)
val burrow_deactivate : parameters -> burrow -> (burrow * tok)

(** Set the delegate of a burrow. *)
val burrow_set_delegate : parameters -> Ligo.key_hash option -> burrow -> burrow

(* ************************************************************************* *)
(*                          Liquidation-related                              *)
(* ************************************************************************* *)
(* Some notes:
 * - Notes about the formulas live in docs/burrow-state-liquidations.md
 * - If we deplete the collateral then the next liquidation will close the burrow
 *   (unless the owner collateralizes it).
*)

type liquidation_details =
  { liquidation_reward : tok;
    collateral_to_auction : tok;
    burrow_state : burrow;
  }

val show_liquidation_details : liquidation_details -> string
val pp_liquidation_details : Format.formatter -> liquidation_details -> unit

type liquidation_type =
  (* partial: some collateral remains in the burrow *)
  | Partial
  (* complete: deplete the collateral *)
  | Complete
  (* complete: deplete the collateral AND the creation deposit *)
  | Close

type liquidation_result = (liquidation_type * liquidation_details) option

val compute_min_kit_for_unwarranted : parameters -> burrow -> tok -> kit option
val compute_expected_kit : parameters -> tok -> ratio

val show_liquidation_type : liquidation_type -> string
val pp_liquidation_type : Format.formatter -> liquidation_type -> unit

val show_liquidation_result : liquidation_result -> string
val pp_liquidation_result : Format.formatter -> liquidation_result -> unit

val burrow_request_liquidation : parameters -> burrow -> liquidation_result

(* BEGIN_OCAML *)
val burrow_collateral : burrow -> tok
val burrow_active : burrow -> bool

val make_burrow_for_test :
  active:bool ->
  address:Ligo.address ->
  delegate:(Ligo.key_hash option) ->
  collateral:tok ->
  outstanding_kit:kit ->
  adjustment_index:fixedpoint ->
  collateral_at_auction:tok ->
  last_checker_timestamp:Ligo.timestamp ->
  burrow

val compute_collateral_to_auction : parameters -> burrow -> Ligo.int

(** NOTE: For testing only. Check whether a burrow is overburrowed, assuming
  * that all collateral that is in auctions at the moment will be sold at the
  * current minting price, but that all these liquidations were actually
  * warranted. *)
val burrow_is_optimistically_overburrowed : parameters -> burrow -> bool

(* Additional record accessor for testing purposes only *)
val burrow_outstanding_kit : burrow -> kit
(* END_OCAML *)
