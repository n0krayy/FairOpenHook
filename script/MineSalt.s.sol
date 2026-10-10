// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

/// @notice Mines HOOK_SALT for a FairOpenHook deployment on Robinhood Chain.
/// @dev The salt is bound to (deployer, initcode, constructor args) — re-mine
///      if any param changes. Run: forge script script/MineSalt.s.sol
contract MineSalt is Script {
    address constant DEPLOYER = 0x2f8cb181d0D292c5812631CC07eD6f1e90E0B385;
    address constant V4_POOL_MANAGER_ROBINHOOD = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD_ROBINHOOD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant TREASURY = 0xdC124328B621243422661BdfF50152d7F5f60efa;

    function run() external view {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        FairOpenHook.Params memory p = FairOpenHook.Params({
            windowBlocks: 100,
            baseFee: 3_000,
            maxFee: 900_000,
            feeK: 150,
            breakerBps: 2_500,
            maxBuyPerWallet: 4_500_000 ether,
            cooldownBlocks: 3,
            treasury: TREASURY,
            pairToken: IMD_ROBINHOOD
        });

        (address hookAddr, bytes32 salt) = HookMiner.find(
            DEPLOYER, flags, type(FairOpenHook).creationCode, abi.encode(IPoolManager(V4_POOL_MANAGER_ROBINHOOD), p)
        );

        console.log("deployer:", DEPLOYER);
        console.log("hook:", hookAddr);
        console.log("HOOK_SALT:");
        console.logBytes32(salt);
    }
}
