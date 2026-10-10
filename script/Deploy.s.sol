// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";

/// @notice Deploys FairOpenHook against IMD's PoolManager.
/// @dev The hook address must encode the permission flags. Mine the salt with
///      HookMiner (see test/FairOpenHook.t.sol) and pass it via HOOK_SALT.
///      For mainnet, deploy through the canonical CREATE2 deployer proxy
///      (0x4e59b44847b379578588920cA78FbF26c0B4956C) so the mined address holds.
contract Deploy is Script {
    address constant IMD_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envBytes32("HOOK_SALT");

        FairOpenHook.Params memory p = FairOpenHook.Params({
            windowBlocks: 100,
            baseFee: 3_000, // 0.30%
            maxFee: 900_000, // 90%
            feeK: 150, // 10% price impact -> +15% fee (tuned 2026-10-10 via attack-replay)
            breakerBps: 2_500, // 25%
            maxBuyPerWallet: 4_500_000 ether, // 0.5% of 900M — VERIFY token decimals before mainnet
            cooldownBlocks: 3,
            // Treasury = the IMD flywheel sink for the surcharge (e.g. staking distributor
            // or a burn/LP splitter). Immutable at deploy. Set via TREASURY_ADDRESS env.
            treasury: vm.envOr("TREASURY_ADDRESS", address(0))
        });

        vm.startBroadcast(deployerKey);
        FairOpenHook hook = new FairOpenHook{salt: salt}(IPoolManager(IMD_POOL_MANAGER), p);
        vm.stopBroadcast();

        console.log("FairOpenHook deployed:", address(hook));
    }
}
