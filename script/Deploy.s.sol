// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";

/// @notice Deploys FairOpenHook.
/// @dev Targets IMD's PoolManager on Ethereum mainnet, or the canonical V4
///      PoolManager on Robinhood Chain (chainid 4663). The hook address must
///      encode the permission flags — mine HOOK_SALT with HookMiner for the
///      deployer address on the target chain (see test/FairOpenHook.t.sol).
contract Deploy is Script {
    // Ethereum mainnet
    address constant IMD_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD_ETHEREUM = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    // Robinhood Chain (chainid 4663)
    address constant V4_POOL_MANAGER_ROBINHOOD = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD_ROBINHOOD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envBytes32("HOOK_SALT");

        (address poolManager, address pairToken) = block.chainid == 4663
            ? (V4_POOL_MANAGER_ROBINHOOD, IMD_ROBINHOOD)
            : (IMD_POOL_MANAGER, IMD_ETHEREUM);
        // env overrides (optional)
        pairToken = vm.envOr("PAIR_TOKEN", pairToken);

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
            treasury: vm.envOr("TREASURY_ADDRESS", address(0)),
            pairToken: pairToken
        });

        vm.startBroadcast(deployerKey);
        FairOpenHook hook = new FairOpenHook{salt: salt}(IPoolManager(poolManager), p);
        vm.stopBroadcast();

        console.log("chain:", block.chainid);
        console.log("poolManager:", poolManager);
        console.log("pairToken:", pairToken);
        console.log("FairOpenHook deployed:", address(hook));
    }
}
