// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Keycard} from "../src/Keycard.sol";

/// @notice Deploys Keycard to Arc and publishes one demo plan.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url arc --private-key $ARC_DEPLOYER_KEY --broadcast
///
/// Gas is paid in native USDC (18 decimals). At Arc's 20 Gwei floor a deployment of
/// this size costs well under a cent, but the deployer still needs a USDC balance.
contract Deploy is Script {
    /// Demo plan: 1.00 USDC (6 decimals) for 30 days of access.
    uint128 internal constant DEMO_PRICE_USDC = 1_000_000;
    uint64 internal constant DEMO_PERIOD = 30 days;

    function run() external {
        vm.startBroadcast();

        Keycard keycard = new Keycard();
        uint256 planId = keycard.createPlan("Demo access pass", DEMO_PRICE_USDC, DEMO_PERIOD);

        vm.stopBroadcast();

        (uint256 native, uint256 usdc) = keycard.quote(planId, 1);

        console.log("Keycard deployed at:", address(keycard));
        console.log("Demo plan id:       ", planId);
        console.log("Price (6dp USDC):   ", usdc);
        console.log("Price (18dp native):", native);
    }
}
