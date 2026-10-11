// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

/// @notice Mines HOOK_SALT for the FairOpenHook testnet demo deployment.
/// @dev Deployer is our SimpleFactory (the testnet CREATE2 proxy is non-standard).
///      Update FACTORY if redeployed.
contract MineSaltTestnet is Script {
    address constant FACTORY = 0xAD00044A623Ba1ba1b402f50f7A1F0B502208559;
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TIMD_TESTNET = 0x45a082747965769F033ae7FA7Ebdb8bb62e863ba;
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
            pairToken: TIMD_TESTNET
        });

        (address hookAddr, bytes32 salt) = HookMiner.find(
            FACTORY, flags, type(FairOpenHook).creationCode, abi.encode(IPoolManager(V4_POOL_MANAGER), p)
        );

        console.log("factory:", FACTORY);
        console.log("hook:", hookAddr);
        console.log("HOOK_SALT:");
        console.logBytes32(salt);
    }
}
