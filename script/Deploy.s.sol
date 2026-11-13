// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockUSDG} from "../src/MockUSDG.sol";

/// Deploys MilestoneEscrow, and MockUSDG when DEPLOY_MOCK_TOKEN=true (testnet has no USDG).
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        MilestoneEscrow esc = new MilestoneEscrow();
        console.log("MilestoneEscrow:", address(esc));
        if (vm.envOr("DEPLOY_MOCK_TOKEN", false)) {
            MockUSDG tok = new MockUSDG();
            console.log("MockUSDG:", address(tok));
        }
        vm.stopBroadcast();
    }
}
