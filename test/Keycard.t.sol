// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Keycard} from "../src/Keycard.sol";

/// @dev Stands in for an address that cannot receive native value — on Arc this is
///      what a blocklisted party behaves like from the contract's point of view.
contract RejectsValue {
    Keycard private immutable keycard;

    constructor(Keycard k) {
        keycard = k;
    }

    function createPlan(string calldata name, uint128 priceUsdc, uint64 period) external returns (uint256) {
        return keycard.createPlan(name, priceUsdc, period);
    }

    function withdraw() external returns (uint256) {
        return keycard.withdraw();
    }

    receive() external payable {
        revert("no value accepted");
    }
}

contract KeycardTest is Test {
    Keycard internal keycard;

    address internal merchant = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint128 internal constant PRICE_USDC = 5_000_000; // 5.00 USDC, 6 decimals
    uint64 internal constant PERIOD = 30 days;

    uint256 internal planId;

    function setUp() public {
        keycard = new Keycard();
        vm.prank(merchant);
        planId = keycard.createPlan("VPN monthly", PRICE_USDC, PERIOD);

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    // --- the decimal boundary, which is the whole point ---------------------

    function test_quoteCrossesDecimalBoundaryExactly() public view {
        (uint256 native, uint256 usdc) = keycard.quote(planId, 1);
        assertEq(usdc, 5_000_000, "price should stay 6-decimal USDC");
        assertEq(native, 5_000_000 * 1e12, "msg.value is 18-decimal native");
        // 5.00 USDC either way — one balance, two representations.
        assertEq(native / 1e12, usdc);
    }

    function test_conversionHelpersRoundTrip() public view {
        assertEq(keycard.toNative(5_000_000), 5e18);
        assertEq(keycard.toUsdc(5e18), 5_000_000);
    }

    /// A caller who pays the 6-decimal number as if it were native underpays by 1e12.
    /// This is exactly the silent bug Arc developers hit; here it reverts loudly.
    function test_payingSixDecimalAmountAsNativeReverts() public {
        (uint256 native, uint256 usdc) = keycard.quote(planId, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Keycard.Underpaid.selector, native, usdc));
        keycard.subscribe{value: usdc}(planId, 1);
    }

    // --- paying --------------------------------------------------------------

    function test_exactPaymentGrantsAccess() public {
        (uint256 native,) = keycard.quote(planId, 1);

        vm.prank(alice);
        uint64 expiry = keycard.subscribe{value: native}(planId, 1);

        assertTrue(keycard.isActive(planId, alice));
        assertEq(expiry, uint64(block.timestamp) + PERIOD);
        assertEq(keycard.withdrawable(merchant), native);
        assertEq(keycard.remaining(planId, alice), PERIOD);
    }

    function test_inactiveBeforePaying() public view {
        assertFalse(keycard.isActive(planId, alice));
        assertEq(keycard.remaining(planId, alice), 0);
    }

    function test_accessLapsesAfterPeriod() public {
        (uint256 native,) = keycard.quote(planId, 1);
        vm.prank(alice);
        keycard.subscribe{value: native}(planId, 1);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + PERIOD + 1);
        assertFalse(keycard.isActive(planId, alice));
    }

    function test_multiplePeriodsScaleLinearly() public {
        (uint256 native,) = keycard.quote(planId, 3);
        assertEq(native, 3 * 5e18);

        vm.prank(alice);
        uint64 expiry = keycard.subscribe{value: native}(planId, 3);
        assertEq(expiry, uint64(block.timestamp) + 3 * PERIOD);
    }

    // --- dust must never be truncated ---------------------------------------

    /// Arc warns that fractional amounts below 6 decimals persist onchain. A single
    /// wei of overpayment must survive as credit, not vanish into rounding.
    function test_subSixDecimalDustIsCreditedNotTruncated() public {
        (uint256 native,) = keycard.quote(planId, 1);

        vm.prank(alice);
        keycard.subscribe{value: native + 1}(planId, 1);

        assertEq(keycard.withdrawable(alice), 1, "1 wei of dust must be credited");
        assertEq(keycard.toUsdc(1), 0, "and it would have rounded to zero USDC");
        assertEq(keycard.withdrawable(merchant), native, "merchant still gets exactly the price");
    }

    function test_overpaymentIsCreditedToPayer() public {
        (uint256 native,) = keycard.quote(planId, 1);

        vm.prank(alice);
        keycard.subscribe{value: native + 2e18}(planId, 1);

        assertEq(keycard.withdrawable(alice), 2e18);

        uint256 before = alice.balance;
        vm.prank(alice);
        keycard.withdraw();
        assertEq(alice.balance - before, 2e18);
    }

    // --- renewal semantics ---------------------------------------------------

    function test_earlyRenewalExtendsFromExpiryNotNow() public {
        (uint256 native,) = keycard.quote(planId, 1);

        vm.prank(alice);
        uint64 first = keycard.subscribe{value: native}(planId, 1);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 days); // renew with 20 days still unused
        vm.prank(alice);
        uint64 second = keycard.subscribe{value: native}(planId, 1);

        assertEq(second, first + PERIOD, "unused time must not be burned");
    }

    function test_renewalAfterLapseStartsFromNow() public {
        (uint256 native,) = keycard.quote(planId, 1);

        vm.prank(alice);
        keycard.subscribe{value: native}(planId, 1);

        vm.warp(vm.getBlockTimestamp() + PERIOD + 5 days);
        vm.prank(alice);
        uint64 second = keycard.subscribe{value: native}(planId, 1);

        assertEq(second, uint64(vm.getBlockTimestamp()) + PERIOD);
    }

    function test_subscribersAreIndependent() public {
        (uint256 native,) = keycard.quote(planId, 1);

        vm.prank(alice);
        keycard.subscribe{value: native}(planId, 1);

        assertTrue(keycard.isActive(planId, alice));
        assertFalse(keycard.isActive(planId, bob));
    }

    // --- payouts are pull, so a blocked merchant cannot brick the rail -------

    function test_merchantThatCannotReceiveValueDoesNotBlockSubscribers() public {
        RejectsValue blocked = new RejectsValue(keycard);
        uint256 blockedPlan = blocked.createPlan("blocked merchant", PRICE_USDC, PERIOD);

        (uint256 native,) = keycard.quote(blockedPlan, 1);

        // The subscriber still gets access...
        vm.prank(alice);
        keycard.subscribe{value: native}(blockedPlan, 1);
        assertTrue(keycard.isActive(blockedPlan, alice));

        // ...and only the merchant's own withdrawal fails.
        vm.expectRevert(Keycard.TransferFailed.selector);
        blocked.withdraw();
    }

    function test_withdrawZeroReverts() public {
        vm.prank(merchant);
        vm.expectRevert(Keycard.NothingToWithdraw.selector);
        keycard.withdraw();
    }

    function test_withdrawClearsBalance() public {
        (uint256 native,) = keycard.quote(planId, 1);
        vm.prank(alice);
        keycard.subscribe{value: native}(planId, 1);

        vm.prank(merchant);
        keycard.withdraw();

        assertEq(keycard.withdrawable(merchant), 0);
        assertEq(merchant.balance, native);
    }

    // --- plan administration -------------------------------------------------

    function test_onlyMerchantTogglesPlan() public {
        vm.prank(alice);
        vm.expectRevert(Keycard.NotMerchant.selector);
        keycard.setPlanActive(planId, false);
    }

    function test_inactivePlanRejectsNewSubscriptions() public {
        vm.prank(merchant);
        keycard.setPlanActive(planId, false);

        (uint256 native,) = keycard.quote(planId, 1);
        vm.prank(alice);
        vm.expectRevert(Keycard.PlanInactive.selector);
        keycard.subscribe{value: native}(planId, 1);
    }

    function test_unknownPlanReverts() public {
        vm.expectRevert(Keycard.NoSuchPlan.selector);
        keycard.quote(999, 1);
    }

    function test_zeroPeriodPlanRejected() public {
        vm.prank(merchant);
        vm.expectRevert(Keycard.ZeroPeriod.selector);
        keycard.createPlan("bad", PRICE_USDC, 0);
    }

    function test_zeroPeriodsRejected() public {
        vm.expectRevert(Keycard.BadPeriods.selector);
        keycard.quote(planId, 0);
    }

    function test_tooManyPeriodsRejected() public {
        // Read the bound first: vm.expectRevert applies to the very next call, and a
        // getter invoked after it would swallow the expectation.
        uint256 tooMany = keycard.MAX_PERIODS() + 1;

        vm.expectRevert(Keycard.BadPeriods.selector);
        keycard.quote(planId, tooMany);
    }

    /// A merchant setting an absurd period must not silently truncate the expiry.
    function test_absurdPeriodCannotOverflowExpiry() public {
        vm.prank(merchant);
        uint256 huge = keycard.createPlan("overflow", 0, type(uint64).max);

        vm.prank(alice);
        vm.expectRevert(Keycard.BadPeriods.selector);
        keycard.subscribe{value: 0}(huge, 2);
    }

    /// Free tiers ride the same rail, which is how a trial becomes a paid plan
    /// without a second integration.
    function test_freePlanGrantsAccessWithoutPayment() public {
        vm.prank(merchant);
        uint256 freePlan = keycard.createPlan("trial", 0, 7 days);

        vm.prank(alice);
        keycard.subscribe{value: 0}(freePlan, 1);
        assertTrue(keycard.isActive(freePlan, alice));
    }

    // --- fuzz ---------------------------------------------------------------

    function testFuzz_neverAcceptsUnderpayment(uint96 sent) public {
        (uint256 native,) = keycard.quote(planId, 1);
        vm.assume(sent < native);

        vm.deal(bob, native);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Keycard.Underpaid.selector, native, uint256(sent)));
        keycard.subscribe{value: sent}(planId, 1);
    }

    function testFuzz_merchantCreditPlusPayerCreditEqualsPaid(uint96 extra) public {
        (uint256 native,) = keycard.quote(planId, 1);
        uint256 sent = native + uint256(extra);

        vm.deal(alice, sent);
        vm.prank(alice);
        keycard.subscribe{value: sent}(planId, 1);

        assertEq(keycard.withdrawable(merchant) + keycard.withdrawable(alice), sent, "no value may be created or lost");
    }
}
