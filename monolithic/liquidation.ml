open Tez
open Kit
open Burrow
open FixedPoint
open Parameters

(* Some notes:
 * - Notes about the formulas live in docs/burrow-state-liquidations.md
 * - If we deplete the collateral then the next liquidation will close the burrow
 *   (unless the owner collateralizes it).
*)

type liquidation_outcome =
  | Unnecessary (* the burrow does not qualify for liquidation *)
  | Partial     (* partial: some collateral remains in the burrow *)
  | Complete    (* complete: deplete the collateral *)
  | Close       (* complete: deplete the collateral AND the creation deposit *)
[@@deriving show]

type liquidation_result =
  { outcome : liquidation_outcome;
    liquidation_reward : Tez.t;
    tez_to_auction : Tez.t;
    expected_kit : Kit.t;
    min_received_kit_for_unwarranted : Kit.t; (* If we get this many kit or more, the liquidation was unwarranted *)
    burrow_state : Burrow.t;
  }
[@@deriving show]

let compute_min_received_kit_for_unwarranted (p: Parameters.t) (b: Burrow.t) (tez_to_auction: Tez.t) : Kit.t =
  assert (p.last_touched = b.last_touched);
  assert (b.collateral <> Tez.zero); (* NOTE: division by zero *)
  let expected_kit = Burrow.compute_expected_kit p b.collateral_at_auction in
  let optimistic_outstanding = Kit.(b.outstanding_kit - expected_kit) in
  Kit.scale Kit.one FixedPoint.(Tez.to_fp tez_to_auction * (Constants.fminus * Kit.to_fp optimistic_outstanding) / Tez.to_fp b.collateral)

(** Compute whether the liquidation of an auction slice was (retroactively)
  * unwarranted or not. *)
let was_slice_liquidation_unwarranted
    (* Original amount of tez sent to liquidation queue *)
    (tez_to_auction: Tez.t)
    (* Pre-calculated minimum amount of kit required to receive when selling
     * tez_to_auction to consider the liquidation unwarranted *)
    (min_received_kit_for_unwarranted: Kit.t)
    (* The slice of tez_to_auction that we have sold *)
    (liquidation_slice: Tez.t)
    (* The amount of kit we received for liquidation_slice *)
    (liquidation_earning: Kit.t)
  : bool =
  FixedPoint.(Tez.to_fp tez_to_auction * Kit.to_fp liquidation_earning >= Kit.to_fp min_received_kit_for_unwarranted * Tez.to_fp liquidation_slice)

let request_liquidation (p: Parameters.t) (b: Burrow.t) : liquidation_result =
  assert (p.last_touched = b.last_touched);
  let partial_reward = Tez.scale b.collateral Constants.liquidation_reward_percentage in
  (* Only applies if the burrow qualifies for liquidation; it is to be given to
   * the actor triggering the liquidation. *)
  let liquidation_reward = Tez.(Constants.creation_deposit + partial_reward) in
  if not (Burrow.is_liquidatable p b) then
    (* Case 1: The outstanding kit does not exceed the liquidation limit; we
     * shouldn't liquidate the burrow, it's solid. *)
    { outcome = Unnecessary;
      liquidation_reward = Tez.zero;
      tez_to_auction = Tez.zero;
      expected_kit = Kit.zero;
      min_received_kit_for_unwarranted = Kit.zero; (* todo: use better representation *)
      burrow_state = b }
  else if Tez.(b.collateral - partial_reward) < Constants.creation_deposit then
    (* Case 2a: Cannot even refill the creation deposit; liquidate the whole
     * thing (after paying the liquidation reward of course). *)
    let tez_to_auction = Tez.(b.collateral - partial_reward) in
    let expected_kit = Burrow.compute_expected_kit p tez_to_auction in
    let final_burrow =
      { b with
        active = false;
        collateral = Tez.zero;
        outstanding_kit = Kit.zero;
      } in
    { outcome = Close;
      liquidation_reward = liquidation_reward;
      tez_to_auction = tez_to_auction;
      expected_kit = expected_kit;
      min_received_kit_for_unwarranted = compute_min_received_kit_for_unwarranted p b tez_to_auction;
      burrow_state = final_burrow }
  else
    (* Case 2b: We can replenish the creation deposit. Now we gotta see if it's
     * possible to liquidate the burrow partially or if we have to do so
     * completely (deplete the collateral). *)
    let b_without_reward = { b with collateral = Tez.(b.collateral - partial_reward - Constants.creation_deposit) } in
    let tez_to_auction = Burrow.compute_tez_to_auction p b_without_reward in

    if tez_to_auction < Tez.zero || tez_to_auction > b_without_reward.collateral then
      (* Case 2b.1: With the current price it's impossible to make the burrow
       * not undercollateralized; pay the liquidation reward, stash away the
       * creation deposit, and liquidate all the remaining collateral, even if
       * it is not expected to repay enough kit. *)
      let tez_to_auction = b_without_reward.collateral in (* OVERRIDE *)
      let expected_kit = Burrow.compute_expected_kit p tez_to_auction in
      let final_burrow =
        { b with
          collateral = Tez.zero;
          collateral_at_auction = Tez.(b.collateral_at_auction + tez_to_auction);
        } in
      { outcome = Complete;
        liquidation_reward = liquidation_reward;
        tez_to_auction = tez_to_auction;
        expected_kit = expected_kit;
        min_received_kit_for_unwarranted = compute_min_received_kit_for_unwarranted p b tez_to_auction;
        burrow_state = final_burrow }
    else
      (* Case 2b.2: Recovery is possible; pay the liquidation reward, stash away the
       * creation deposit, and liquidate the collateral needed to underburrow
       * the burrow (assuming that the past auctions will be successful but
       * warranted, and that the liquidation we are performing will also be
       * deemed warranted). If---when the auction is over---we realize that the
       * liquidation was not really warranted, we shall return the auction
       * earnings in their entirety. If not, then only 90% of the earnings
       * shall be returned. *)
      let expected_kit = Burrow.compute_expected_kit p tez_to_auction in
      let final_burrow =
        { b with
          collateral = Tez.(b_without_reward.collateral - tez_to_auction);
          collateral_at_auction = Tez.(b.collateral_at_auction + tez_to_auction);
        } in
      { outcome = Partial;
        liquidation_reward = liquidation_reward;
        tez_to_auction = tez_to_auction;
        expected_kit = expected_kit;
        min_received_kit_for_unwarranted = compute_min_received_kit_for_unwarranted p b tez_to_auction;
        burrow_state = final_burrow }
