open OUnit2
open Checker
open Burrow

let bob = Address.of_string "bob"
let alice = Address.of_string "alice"

let assert_ok (r: ('a, Error.error) result) : 'a =
  match r with
  | Ok a -> a
  | Error LiquidationAuction.BidTooLow -> assert_failure "BidTooLow"
  | Error LiquidationAuction.NotAWinningBid -> assert_failure "NotAWinningBid"
  | Error LiquidationAuction.NotAllSlicesClaimed -> assert_failure "NotAllSlicesClaimed"
  | Error (Burrow.InsufficientFunds _) -> assert_failure "InsufficientFunds"
  | Error Burrow.WithdrawTezFailure -> assert_failure "WithdrawTezFailure"
  | Error Burrow.MintKitFailure -> assert_failure "MintKitFailure"
  | Error Checker.OwnershipMismatch _ -> assert_failure "OwnershipMismatch"
  | Error Checker.NonExistentBurrow _ -> assert_failure "NonExistentBurrow"
  | Error Checker.NotLiquidationCandidate _ -> assert_failure "NotLiquidationCandidate"
  | Error _ -> assert_failure "Unknown Error"

let suite =
  "Checker tests" >::: [
    ("can complete a liquidation auction" >::
     fun _ ->
       let t0 = Timestamp.of_seconds 0 in
       let l0 = Level.of_int 0 in
       let checker = Checker.initialize t0 l0 in

       let (burrow_id, checker) = assert_ok @@
         Checker.create_burrow
           checker
           ~owner:bob
           ~amount:(Tez.of_mutez 10_000_000) in

       let (kit, checker) = assert_ok @@
         Checker.mint_kit
           checker
           ~owner:bob
           ~burrow_id:burrow_id
           ~amount:(Kit.of_mukit 4_285_714) in
       assert_equal kit (Kit.of_mukit 4_285_714);

       let int_level = 5 in
       let tezos = Tezos.{
           now = Timestamp.of_seconds @@ int_level * 60;
           level = Level.of_int int_level;
         } in

       let touch_reward, checker =
         Checker.touch
           checker
           ~tezos
           ~index:(FixedPoint.of_string "1.2") in

       let checker = assert_ok @@
         Checker.touch_burrow checker burrow_id in

       assert_equal (Kit.of_mukit 500_001) touch_reward ~printer:Kit.show;

       let (reward, checker) = assert_ok @@
         Checker.mark_for_liquidation
           checker
           ~liquidator:alice
           ~burrow_id:burrow_id in
       assert_equal reward (Tez.of_mutez 1_009_000) ~printer:Tez.show;

       let int_level = 10 in
       let tezos = Tezos.{
           now = Timestamp.of_seconds @@ int_level * 60;
           level = Level.of_int int_level;
         } in

       let touch_reward, checker =
         Checker.touch
           checker
           ~tezos
           ~index:(FixedPoint.of_string "1.2") in

       assert_bool "should start an auction"
         (Option.is_some checker.liquidation_auctions.current_auction);

       assert_equal (Kit.of_mukit 500_001) touch_reward ~printer:Kit.show;

       let int_level = 15 in
       let tezos = Tezos.{
           now = Timestamp.of_seconds @@ int_level * 60;
           level = Level.of_int int_level;
         } in

       let touch_reward, checker =
         Checker.touch
           checker
           ~tezos
           ~index:(FixedPoint.of_string "1.2") in

       let (bid, checker) = assert_ok @@
         Checker.liquidation_auction_place_bid
           checker
           ~tezos
           ~sender:alice
           ~amount:(Kit.of_mukit 4_200_000) in

       assert_equal (Kit.of_mukit 500_001) touch_reward ~printer:Kit.show;

       let int_level = 45 in
       let tezos = Tezos.{
           now = Timestamp.of_seconds @@ int_level * 60;
           level = Level.of_int int_level;
         } in

       let touch_reward, checker =
         Checker.touch
           checker
           ~tezos
           ~index:(FixedPoint.of_string "1.2") in

       assert_bool "auction should be completed"
         (Option.is_none checker.liquidation_auctions.current_auction);

       assert_equal (Kit.of_mukit 21_000_006) touch_reward ~printer:Kit.show;

       let slice =
         (PtrMap.find burrow_id checker.burrows)
         |> Burrow.liquidation_slices
         |> Option.get
         |> fun i -> i.youngest in

       let checker =
         Checker.touch_liquidation_slices
           checker
           [slice] in

       let result = PtrMap.find burrow_id checker.burrows in
       assert_bool "burrow should have no liquidation slices"
         (Option.is_none (Burrow.liquidation_slices result));

       assert_equal
         Tez.zero
         (Burrow.collateral_at_auction result)
         ~printer:Tez.show;

       let (tez_from_bid, _checker) = assert_ok @@
         Checker.liquidation_auction_reclaim_winning_bid
           checker
           ~address:alice
           ~bid_ticket:bid in

       assert_equal (Tez.of_mutez 3_156_182) tez_from_bid
         ~printer:Tez.show;
    );
  ]