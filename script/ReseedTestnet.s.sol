// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DemoSetup} from "../src/DemoSetup.sol";

/// @notice Re-seeds the testnet demo pool with in-range liquidity.
/// @dev The first DemoSetup placed liquidity at ticks -600..600 (out of range).
///      This deploys a new seeder at ticks 128400..129600 (around tick 128998)
///      and adds liquidity WITHOUT re-initializing the pool.
contract ReseedTestnet is Script {
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TIMD = 0x45a082747965769F033ae7FA7Ebdb8bb62e863ba;
    address constant DCC = 0xbEeF73adc410fc6347531A9887cC436Df8C6886B;
    address constant HOOK = 0xaC99c7a214945C782941e6958688834768c520C8;
    uint160 constant SQRT_PRICE_X96 = 50108289675009590667816866938880;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        DemoSetup seeder = new DemoSetup(
            IPoolManager(V4_POOL_MANAGER),
            TIMD,
            DCC,
            HOOK,
            SQRT_PRICE_X96,
            20 ether, // 20 tIMD
            8_000_000 ether, // 8M DCC
            128400, // tickLower
            129600 // tickUpper
        );
        console.log("seeder:", address(seeder));
        seeder.setup(false); // pool already initialized, just add liquidity
        console.log("liquidity seeded in-range");

        vm.stopBroadcast();
    }
}
