open FixedPoint
open Kit
open Tok
open Parameters
open LiquidationAuctionPrimitiveTypes
open Constants
open Error
open Common

[@@@coverage off]

type burrow =
  { (* Whether the creation deposit for the burrow has been paid. If the
     * creation deposit has been paid, the burrow is considered "active" and
     * "closed"/inactive otherwise. Paying the creation deposit re-activates
     * a "closed" burrow. *)
    active : bool;
    (* Address of the contract holding the burrow's collateral. *)
    address: Ligo.address;
    (* The delegate for the tez (collateral + creation_deposit) the burrow
     * holds. *) (* TOKFIX: Should be part of the wrapper contract. *)
    delegate : Ligo.key_hash option;
    (* Collateral currently stored in the burrow. *)
    collateral : tok;
    (* Outstanding kit minted out of the burrow. *)
    outstanding_kit : kit;
    (* The imbalance adjustment index observed the last time the burrow was
     * touched. *)
    adjustment_index : fixedpoint;
    (* Collateral that has been sent off to auctions. For all intents and
     * purposes, this collateral can be considered gone, but depending on the
     * outcome of the auctions we expect some kit in return. *)
    collateral_at_auction : tok;
    (* The timestamp checker had the last time the burrow was touched. *)
    last_checker_timestamp : Ligo.timestamp;
  }
[@@deriving show]

type liquidation_details =
  { liquidation_reward : tok;
    collateral_to_auction : tok;
    burrow_state : burrow;
  }
[@@deriving show]

type liquidation_type =
  (* partial: some collateral remains in the burrow *)
  | Partial
  (* complete: deplete the collateral *)
  | Complete
  (* complete: deplete the collateral AND the creation deposit *)
  | Close
[@@deriving show]

type liquidation_result = (liquidation_type * liquidation_details) option
[@@deriving show]

[@@@coverage on]

(** Update the outstanding kit, update the adjustment index, and the timestamp. *)
let burrow_touch (p: parameters) (burrow: burrow) : burrow =
  let burrow_out = if p.last_touched = burrow.last_checker_timestamp
    then
      burrow
    else
      let current_adjustment_index = compute_adjustment_index p in
      { burrow with
        outstanding_kit =
          kit_of_fraction_floor
            (Ligo.mul_nat_int
               (kit_to_denomination_nat burrow.outstanding_kit)
               (fixedpoint_to_raw current_adjustment_index)
            )
            (Ligo.mul_int_int
               kit_scaling_factor_int
               (fixedpoint_to_raw burrow.adjustment_index)
            );
        adjustment_index = current_adjustment_index;
        last_checker_timestamp = p.last_touched;
      }
  in
  assert (burrow.address = burrow_out.address);
  burrow_out

let[@inline] burrow_address (b: burrow) : Ligo.address =
  b.address

(** Computes the total amount of tok associated with a burrow. This includes
  * the collateral, collateral_at_auction, and the creation_deposit if the
  * burrow is active. *)
let burrow_total_associated_tok (b: burrow) : tok =
  tok_add
    (tok_add b.collateral b.collateral_at_auction)
    (if b.active then creation_deposit else tok_zero)

let[@inline] burrow_collateral_at_auction (b: burrow) : tok =
  b.collateral_at_auction

(** Under-collateralization condition: tok < f * kit * price. *)
let[@inline] undercollateralization_condition (f: ratio) (price: ratio) (tok: ratio) (kit: ratio) : bool =
  let { num = num_f; den = den_f; } = f in
  let { num = num_p; den = den_p; } = price in
  let { num = num_tz; den = den_tz; } = tok in
  let { num = num_kt; den = den_kt; } = kit in
  let lhs =
    Ligo.mul_int_int
      (Ligo.mul_int_int num_tz den_f)
      (Ligo.mul_int_int den_kt den_p) in
  let rhs =
    Ligo.mul_int_int
      (Ligo.mul_int_int num_f num_kt)
      (Ligo.mul_int_int den_tz num_p) in
  Ligo.lt_int_int lhs rhs

(** Check whether a burrow is overburrowed. A burrow is overburrowed if
  *
  *   collateral < fminting * kit_outstanding * minting_price
  *
  * The quantity collateral / (fminting * minting_price) we call the burrowing
  * limit (normally kit_outstanding <= burrowing_limit). NOTE: for the
  * purposes of minting/checking overburrowedness, we do not take into
  * account expected kit from pending auctions; for all we know, this could
  * be lost forever.
*)
let burrow_is_overburrowed (p: parameters) (b: burrow) : bool =
  assert (p.last_touched = b.last_checker_timestamp);
  let tok = { num = tok_to_denomination_int b.collateral; den = tok_scaling_factor_int; } in
  let kit = { num = kit_to_denomination_int b.outstanding_kit; den = kit_scaling_factor_int; } in
  undercollateralization_condition fminting (minting_price p) tok kit

(*  max_kit_outstanding = FLOOR (collateral / (fminting * minting_price)) *)
let burrow_max_mintable_kit (p: parameters) (b: burrow) : kit =
  assert (p.last_touched = b.last_checker_timestamp);
  let { num = num_fm; den = den_fm; } = fminting in
  let { num = num_mp; den = den_mp; } = minting_price p in
  let numerator =
    Ligo.mul_nat_int
      (tok_to_denomination_nat b.collateral)
      (Ligo.mul_int_int den_fm den_mp) in
  let denominator =
    Ligo.mul_int_int
      tok_scaling_factor_int
      (Ligo.mul_int_int num_fm num_mp) in
  kit_of_fraction_floor numerator denominator

let burrow_return_slice_from_auction
    (slice: liquidation_slice_contents)
    (burrow: burrow)
  : burrow =
  assert burrow.active;
  assert (geq_tok_tok burrow.collateral_at_auction slice.tok);
  let burrow_out =
    { burrow with
      collateral = tok_add burrow.collateral slice.tok;
      collateral_at_auction = tok_sub burrow.collateral_at_auction slice.tok;
    } in
  assert (burrow.address = burrow_out.address);
  burrow_out

let burrow_return_kit_from_auction
    (slice: liquidation_slice_contents)
    (kit: kit)
    (burrow: burrow) : burrow * kit * kit =
  assert (geq_tok_tok burrow.collateral_at_auction slice.tok);

  let returned_kit = kit_min burrow.outstanding_kit kit in
  let excess_kit = kit_sub kit returned_kit in

  let burrow_out =
    { burrow with
      outstanding_kit = kit_sub burrow.outstanding_kit returned_kit;
      collateral_at_auction = tok_sub burrow.collateral_at_auction slice.tok;
    } in

  assert (burrow.address = burrow_out.address);
  assert (eq_kit_kit (kit_add returned_kit excess_kit) kit);
  (burrow_out, returned_kit, excess_kit)

let burrow_create (p: parameters) (addr: Ligo.address) (tok: tok) (delegate_opt: Ligo.key_hash option) : burrow =
  if lt_tok_tok tok creation_deposit
  then (Ligo.failwith error_InsufficientFunds : burrow)
  else
    { active = true;
      address = addr;
      delegate = delegate_opt;
      collateral = tok_sub tok creation_deposit;
      outstanding_kit = kit_zero;
      adjustment_index = compute_adjustment_index p;
      collateral_at_auction = tok_zero;
      last_checker_timestamp = p.last_touched; (* NOTE: If checker is up-to-date, the timestamp should be _now_. *)
    }

(** Add non-negative collateral to a burrow. *)
(* TOKFIX: we need a more generic name (e.g., deposit_collateral) *)
let[@inline] burrow_deposit_collateral (p: parameters) (t: tok) (b: burrow) : burrow =
  let b = burrow_touch p b in
  let burrow_out = { b with collateral = tok_add b.collateral t } in
  assert (b.address = burrow_out.address);
  burrow_out

(** Withdraw a non-negative amount of collateral from the burrow, as long as
  * this will not overburrow it. *)
(* TOKFIX: we need a more generic name (e.g., withdraw_collateral) *)
let burrow_withdraw_collateral (p: parameters) (t: tok) (b: burrow) : burrow =
  let b = burrow_touch p b in
  let burrow = { b with collateral = tok_sub b.collateral t } in
  let burrow_out = if burrow_is_overburrowed p burrow
    then (Ligo.failwith error_WithdrawTezFailure : burrow)
    else burrow
  in
  assert (b.address = burrow_out.address);
  burrow_out

(** Mint a non-negative amount of kits from the burrow, as long as this will
  * not overburrow it *)
let burrow_mint_kit (p: parameters) (kit: kit) (b: burrow) : burrow =
  let b = burrow_touch p b in
  let burrow_out =
    let burrow = { b with outstanding_kit = kit_add b.outstanding_kit kit } in
    if burrow_is_overburrowed p burrow
    then (Ligo.failwith error_MintKitFailure : burrow)
    else burrow
  in
  assert (b.address = burrow_out.address);
  burrow_out

(** Deposit/burn a non-negative amount of kit to the burrow. Return the amount
  * of kit burned. *)
let[@inline] burrow_burn_kit (p: parameters) (kit: kit) (b: burrow) : burrow * kit =
  let b = burrow_touch p b in
  let actual_burned = kit_min b.outstanding_kit kit in
  let burrow_out = {b with outstanding_kit = kit_sub b.outstanding_kit actual_burned} in
  assert (b.address = burrow_out.address);
  (burrow_out, actual_burned)

(** Activate a currently inactive burrow. This operation will fail if either
  * the burrow is already active, or if the amount of tez given is less than
  * the creation deposit. *)
let burrow_activate (p: parameters) (tok: tok) (b: burrow) : burrow =
  let b = burrow_touch p b in
  let burrow_out =
    if lt_tok_tok tok creation_deposit then
      (Ligo.failwith error_InsufficientFunds : burrow)
    else if b.active then
      (Ligo.failwith error_BurrowIsAlreadyActive : burrow)
    else
      { b with
        active = true;
        collateral = tok_sub tok creation_deposit;
      }
  in
  assert (b.address = burrow_out.address);
  burrow_out

(** Deativate a currently active burrow. This operation will fail if the burrow
  * (a) is already inactive, or (b) is overburrowed, or (c) has kit
  * outstanding, or (d) has collateral sent off to auctions. *)
let burrow_deactivate (p: parameters) (b: burrow) : (burrow * tok) =
  let b = burrow_touch p b in
  let burrow_out, return =
    if burrow_is_overburrowed p b then
      (Ligo.failwith error_DeactivatingAnOverburrowedBurrow : (burrow * tok))
    else if (not b.active) then
      (Ligo.failwith error_DeactivatingAnInactiveBurrow : (burrow * tok))
    else if gt_kit_kit b.outstanding_kit kit_zero then
      (Ligo.failwith error_DeactivatingWithOutstandingKit : (burrow * tok))
    else if gt_tok_tok b.collateral_at_auction tok_zero then
      (Ligo.failwith error_DeactivatingWithCollateralAtAuctions : (burrow * tok))
    else
      let return = tok_add b.collateral creation_deposit in
      let updated_burrow =
        { b with
          active = false;
          collateral = tok_zero;
        } in
      (updated_burrow, return)
  in
  assert (b.address = burrow_out.address);
  burrow_out, return

let burrow_set_delegate (p: parameters) (new_delegate: Ligo.key_hash option) (b: burrow) : burrow =
  let b = burrow_touch p b in
  let burrow_out = { b with delegate = new_delegate; } in
  assert (b.address = burrow_out.address);
  burrow_out

(* ************************************************************************* *)
(**                          LIQUIDATION-RELATED                             *)
(* ************************************************************************* *)

(** Compute the number of tez that needs to be auctioned off so that the burrow
  * can return to a state when it is no longer overburrowed or having a risk of
  * liquidation (assuming the current expected minting price). For its
  * calculation, see docs/burrow-state-liquidations.md.  Note that it's skewed
  * on the safe side (overapproximation). This ensures that after a partial
  * liquidation we are no longer "optimistically overburrowed".
  * Returns the number of tez in mutez *)
let compute_collateral_to_auction (p: parameters) (b: burrow) : Ligo.int =

  let { num = num_fm; den = den_fm; } = fminting in
  let { num = num_mp; den = den_mp; } = minting_price p in
  (* Note that num_lp and den_lp here are actually = 1 - liquidation_penalty *)
  let { num = num_lp; den = den_lp; } =
    let { num = num_lp; den = den_lp; } = liquidation_penalty in
    { num = Ligo.sub_int_int den_lp num_lp; den = den_lp; }
  in

  (* numerator = tez_sf * den_lp * num_fm * num_mp * outstanding_kit
     - kit_sf * den_mp * (num_lp * num_fm * collateral_at_auctions + den_lp * den_fm * collateral) *)
  let numerator =
    Ligo.sub_int_int
      (Ligo.mul_int_int
         tok_scaling_factor_int
         (Ligo.mul_int_int
            den_lp
            (Ligo.mul_int_int
               num_fm
               (Ligo.mul_int_nat
                  num_mp
                  (kit_to_denomination_nat b.outstanding_kit)
               )
            )
         )
      )
      (Ligo.mul_int_int
         (Ligo.mul_int_int kit_scaling_factor_int den_mp)
         (Ligo.add_int_int
            (Ligo.mul_int_int num_lp (Ligo.mul_int_nat num_fm (tok_to_denomination_nat b.collateral_at_auction)))
            (Ligo.mul_int_int den_lp (Ligo.mul_int_nat den_fm (tok_to_denomination_nat b.collateral)))
         )
      ) in
  (* denominator = (kit_sf * den_mp * tez_sf) * (num_lp * num_fm - den_lp * den_fm) *)
  let denominator =
    Ligo.mul_int_int
      kit_scaling_factor_int
      (Ligo.mul_int_int
         den_mp
         (Ligo.mul_int_int
            tok_scaling_factor_int
            (Ligo.sub_int_int
               (Ligo.mul_int_int num_lp num_fm)
               (Ligo.mul_int_int den_lp den_fm)
            )
         )
      ) in
  cdiv_int_int (Ligo.mul_int_int numerator tok_scaling_factor_int) denominator

(** Compute the amount of kit we expect to receive from auctioning off an
  * amount of tez, using the current minting price. Since this is an artifice,
  * a mere expectation, we neither floor nor ceil, but instead return the
  * lossless fraction as is. *)
let compute_expected_kit (p: parameters) (collateral_to_auction: tok) : ratio =
  let { num = num_lp; den = den_lp; } = liquidation_penalty in
  let { num = num_mp; den = den_mp; } = minting_price p in
  let numerator =
    Ligo.mul_nat_int
      (tok_to_denomination_nat collateral_to_auction)
      (Ligo.mul_int_int
         (Ligo.sub_int_int den_lp num_lp)
         den_mp
      ) in
  let denominator =
    Ligo.mul_int_int
      tok_scaling_factor_int
      (Ligo.mul_int_int den_lp num_mp) in
  { num = numerator; den = denominator; }

(** Check whether a burrow can be marked for liquidation. A burrow can be
  * marked for liquidation if:
  *
  *   tez_collateral < fliquidation * (kit_outstanding - expected_kit_from_auctions) * liquidation_price
  *
  * The quantity tez_collateral / (fliquidation * liquidation_price) we call the
  * liquidation limit. Note that for this check we optimistically take into
  * account the expected kit from pending auctions (using the current minting
  * price) when computing the outstanding kit. Note that only active burrows
  * can be liquidated; inactive ones are dormant, until either all pending
  * auctions finish or if their creation deposit is restored. *)
let burrow_is_liquidatable (p: parameters) (b: burrow) : bool =
  assert (p.last_touched = b.last_checker_timestamp);

  let tez = { num = tok_to_denomination_int b.collateral; den = tok_scaling_factor_int; } in
  let kit = (* kit = kit_outstanding - expected_kit_from_auctions *)
    let { num = num_ek; den = den_ek; } = compute_expected_kit p b.collateral_at_auction in
    { num =
        Ligo.sub_int_int
          (Ligo.mul_nat_int (kit_to_denomination_nat b.outstanding_kit) den_ek)
          (Ligo.mul_int_int kit_scaling_factor_int num_ek);
      den = Ligo.mul_int_int kit_scaling_factor_int den_ek;
    } in
  b.active && undercollateralization_condition fliquidation (liquidation_price p) tez kit

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
let burrow_is_cancellation_warranted (p: parameters) (b: burrow) (slice_tok: tok) : bool =
  assert (p.last_touched = b.last_checker_timestamp);
  assert (geq_tok_tok b.collateral_at_auction slice_tok);

  let tez = (* tez = collateral + slice *)
    { num = tok_to_denomination_int (tok_add b.collateral slice_tok);
      den = tok_scaling_factor_int;
    } in
  let kit = (* kit = outstanding - compute_expected_kit (collateral_at_auction - slice) *)
    let { num = num_ek; den = den_ek; } =
      compute_expected_kit p (tok_sub b.collateral_at_auction slice_tok) in
    { num =
        Ligo.sub_int_int
          (Ligo.mul_nat_int (kit_to_denomination_nat b.outstanding_kit) den_ek)
          (Ligo.mul_int_int kit_scaling_factor_int num_ek);
      den = Ligo.mul_int_int kit_scaling_factor_int den_ek;
    } in

  b.active && not (undercollateralization_condition fminting (minting_price p) tez kit)

(** Compute the minumum amount of kit to receive for considering the
  * liquidation unwarranted, calculated as (see
  * docs/burrow-state-liquidations.md for the derivation of this formula):
  *
  *   collateral_to_auction * (fliquidation * (outstanding_kit - expected_kit_from_auctions)) / collateral
  *
  * If the burrow has no collateral left in it (e.g., right after a successful
  * Complete-liquidation) then we have two cases:
  * (a) If the outstanding kit is non-zero then there is no way for this
  *     liquidation to be considered unwarranted. outstanding_kit is infinitely
  *     many times greater than the collateral.
  * (b) If the outstanding kit is also zero then the liquidation in question
  *     shouldn't have happened (so it is by definition unwarranted). I think
  *     that this is impossible in practice, but it's probably best to account
  *     for it so that the function is not partial.
*)
let[@inline] compute_min_kit_for_unwarranted (p: parameters) (b: burrow) (collateral_to_auction: tok) : kit option =
  assert (p.last_touched = b.last_checker_timestamp);

  if b.collateral = tok_zero (* NOTE: division by zero. *)
  then
    if not (eq_kit_kit b.outstanding_kit (kit_of_denomination (Ligo.nat_from_literal "0n")))
    then (None: kit option) (* (a): infinity, basically *)
    else (Some kit_zero) (* (b): zero *)
  else
    let { num = num_fl; den = den_fl; } = fliquidation in
    let { num = num_ek; den = den_ek; } = compute_expected_kit p b.collateral_at_auction in

    (* numerator = max 0 (collateral_to_auction * num_fl * (den_ek * outstanding_kit - kit_sf * num_ek)) *)
    let numerator =
      let numerator =
        Ligo.mul_int_int
          (Ligo.mul_nat_int (tok_to_denomination_nat collateral_to_auction) num_fl)
          (Ligo.sub_int_int
             (Ligo.mul_int_nat den_ek (kit_to_denomination_nat b.outstanding_kit))
             (Ligo.mul_int_int kit_scaling_factor_int num_ek)
          ) in
      max_int (Ligo.int_from_literal "0") numerator in

    (* denominator = collateral * den_fl * kit_sf * den_ek *)
    let denominator =
      Ligo.mul_int_int
        (Ligo.mul_nat_int (tok_to_denomination_nat b.collateral) den_fl)
        (Ligo.mul_int_int kit_scaling_factor_int den_ek) in

    Some (kit_of_fraction_ceil numerator denominator) (* Round up here; safer for the system, less so for the burrow *)

let burrow_request_liquidation (p: parameters) (b: burrow) : liquidation_result =
  let b = burrow_touch p b in
  let partial_reward =
    let { num = num_lrp; den = den_lrp; } = liquidation_reward_percentage in
    tok_of_fraction_floor
      (Ligo.mul_nat_int (tok_to_denomination_nat b.collateral) num_lrp)
      (Ligo.mul_int_int tok_scaling_factor_int den_lrp)
  in
  if not (burrow_is_liquidatable p b) then
    (* Case 1: The outstanding kit does not exceed the liquidation limit, or
     * the burrow is already without its creation deposit, inactive; we
     * shouldn't liquidate the burrow. *)
    (None : liquidation_result)
  else
    let liquidation_reward = tok_add creation_deposit partial_reward in
    if lt_tok_tok (tok_sub b.collateral partial_reward) creation_deposit then
      (* Case 2a: Cannot even refill the creation deposit; liquidate the whole
       * thing (after paying the liquidation reward of course). *)
      let collateral_to_auction = tok_sub b.collateral partial_reward in
      let final_burrow =
        { b with
          active = false;
          collateral = tok_zero;
          collateral_at_auction = tok_add b.collateral_at_auction collateral_to_auction;
        } in
      Some
        ( Close,
          { liquidation_reward = liquidation_reward;
            collateral_to_auction = collateral_to_auction;
            burrow_state = final_burrow; }
        )
    else
      (* Case 2b: We can replenish the creation deposit. Now we gotta see if it's
       * possible to liquidate the burrow partially or if we have to do so
       * completely (deplete the collateral). *)
      let b_without_reward = { b with collateral = tok_sub (tok_sub b.collateral partial_reward) creation_deposit } in
      let collateral_to_auction = compute_collateral_to_auction p b_without_reward in

      (* FIXME: The property checked by the following assertion is quite
       * intricate to prove. We probably should include the proof somewhere
       * in the codebase. *)
      assert (Ligo.gt_int_int collateral_to_auction (Ligo.int_from_literal "0"));

      if Ligo.gt_int_int collateral_to_auction (tok_to_denomination_int b_without_reward.collateral) then
        (* Case 2b.1: With the current price it's impossible to make the burrow
         * not undercollateralized; pay the liquidation reward, stash away the
         * creation deposit, and liquidate all the remaining collateral, even if
         * it is not expected to repay enough kit. *)
        let collateral_to_auction = b_without_reward.collateral in (* OVERRIDE *)
        let final_burrow =
          { b with
            collateral = tok_zero;
            collateral_at_auction = tok_add b.collateral_at_auction collateral_to_auction;
          } in
        Some
          ( Complete,
            { liquidation_reward = liquidation_reward;
              collateral_to_auction = collateral_to_auction;
              burrow_state = final_burrow; }
          )
      else
        (* Case 2b.2: Recovery is possible; pay the liquidation reward, stash away the
         * creation deposit, and liquidate the collateral needed to underburrow
         * the burrow (assuming that the past auctions will be successful but
         * warranted, and that the liquidation we are performing will also be
         * deemed warranted). If---when the auction is over---we realize that the
         * liquidation was not really warranted, we shall return the auction
         * earnings in their entirety. If not, then only 90% of the earnings
         * shall be returned. *)
        let collateral_to_auction = match Ligo.is_nat collateral_to_auction with
          | Some collateral -> tok_of_denomination collateral
          (* Note: disabling coverage for this line since it really should be impossible to reach this line *)
          | None -> (Ligo.failwith internalError_ComputeTezToAuctionNegativeResult : tok)
                    [@coverage off]
        in
        let final_burrow =
          { b with
            collateral = tok_sub b_without_reward.collateral collateral_to_auction;
            collateral_at_auction = tok_add b.collateral_at_auction collateral_to_auction;
          } in
        Some
          ( Partial,
            { liquidation_reward = liquidation_reward;
              collateral_to_auction = collateral_to_auction;
              burrow_state = final_burrow; }
          )

(* BEGIN_OCAML *)
[@@@coverage off]
let burrow_collateral (b: burrow) : tok =
  b.collateral

let burrow_active (b: burrow) : bool =
  b.active

let make_burrow_for_test
    ~active
    ~address
    ~delegate
    ~collateral
    ~outstanding_kit
    ~adjustment_index
    ~collateral_at_auction
    ~last_checker_timestamp =
  { delegate = delegate;
    address = address;
    active = active;
    collateral = collateral;
    outstanding_kit = outstanding_kit;
    adjustment_index = adjustment_index;
    collateral_at_auction = collateral_at_auction;
    last_checker_timestamp = last_checker_timestamp;
  }

(** NOTE: For testing only. Check whether a burrow is overburrowed, assuming
  * that all collateral that is in auctions at the moment will be sold at the
  * current minting price, and that all these liquidations were warranted
  * (i.e. liquidation penalties have been paid).
  *
  *   collateral < fminting * (kit_outstanding - expected_kit_from_auctions) * minting_price
*)
let burrow_is_optimistically_overburrowed (p: parameters) (b: burrow) : bool =
  assert (p.last_touched = b.last_checker_timestamp); (* Alternatively: touch the burrow here *)
  let { num = num_fm; den = den_fm; } = fminting in
  let { num = num_mp; den = den_mp; } = minting_price p in
  let { num = num_ek; den = den_ek; } = compute_expected_kit p b.collateral_at_auction in

  (* lhs = collateral * den_fm * kit_sf * den_ek * den_mp *)
  let lhs =
    Ligo.mul_nat_int
      (tok_to_denomination_nat b.collateral)
      (Ligo.mul_int_int
         (Ligo.mul_int_int den_fm kit_scaling_factor_int)
         (Ligo.mul_int_int den_ek den_mp)
      ) in

  (* rhs = num_fm * (kit_outstanding * den_ek - kit_sf * num_ek) * num_mp * tez_sf *)
  let rhs =
    Ligo.mul_int_int
      num_fm
      (Ligo.mul_int_int
         (Ligo.sub_int_int
            (Ligo.mul_nat_int (kit_to_denomination_nat b.outstanding_kit) den_ek)
            (Ligo.mul_int_int kit_scaling_factor_int num_ek)
         )
         (Ligo.mul_int_int num_mp tok_scaling_factor_int)
      ) in

  Ligo.lt_int_int lhs rhs

let burrow_outstanding_kit (b: burrow) : kit = b.outstanding_kit

[@@@coverage on]
(* END_OCAML *)
