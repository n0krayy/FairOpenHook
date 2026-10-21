// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";
import {DemoRouter} from "../src/DemoRouter.sol";
import {DemoSetup} from "../src/DemoSetup.sol";
import {SimpleFactory} from "../src/SimpleFactory.sol";

/// @notice Phase 2 of testnet demo: deploys FairOpenHook, DemoRouter, and
///         creates + seeds the demo pool (tIMD/DCC) with the hook attached.
/// @dev Run on Robinhood Testnet (46630) after DeployTokensTestnet.
///      forge script script/DeployDemoTestnet.s.sol --rpc-url <testnet> --broadcast
contract DeployDemoTestnet is Script {
    address constant FACTORY = 0xAD00044A623Ba1ba1b402f50f7A1F0B502208559;
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TIMD = 0x45a082747965769F033ae7FA7Ebdb8bb62e863ba;
    address constant DCC = 0xbEeF73adc410fc6347531A9887cC436Df8C6886B;
    address constant TREASURY = 0xdC124328B621243422661BdfF50152d7F5f60efa;
    bytes32 constant HOOK_SALT = 0x000000000000000000000000000000000000000000000000000000000000644f;

    // 400k DCC per tIMD (1 DCC = 2.5e-6 tIMD, like real launches)
    uint160 constant SQRT_PRICE_X96 = 50108289675009590667816866938880;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. hook via our SimpleFactory (CREATE2)
        FairOpenHook.Params memory p = FairOpenHook.Params({
            windowBlocks: 100,
            baseFee: 3_000,
            maxFee: 900_000,
            feeK: 150,
            breakerBps: 2_500,
            maxBuyPerWallet: 4_500_000 ether,
            cooldownBlocks: 3,
            treasury: TREASURY,
            pairToken: TIMD
        });
        bytes memory initCode =
            abi.encodePacked(type(FairOpenHook).creationCode, abi.encode(IPoolManager(V4_POOL_MANAGER), p));
        address hook = SimpleFactory(FACTORY).deploy(HOOK_SALT, initCode);
        console.log("hook:", hook);

        // 2. demo router
        DemoRouter router = new DemoRouter(IPoolManager(V4_POOL_MANAGER));
        console.log("router:", address(router));

        // 3. pool + liquidity (20 tIMD + 8M DCC in-range; thin so the demo attack trips the breaker)
        DemoSetup setup = new DemoSetup(
            IPoolManager(V4_POOL_MANAGER),
            TIMD, // token0 (0x45.. < 0xBE..)
            DCC, // token1
            hook,
            SQRT_PRICE_X96,
            20 ether, // 20 tIMD
            8_000_000 ether, // 8M DCC
            int24(-600),
            int24(600)
        );
        console.log("setup (holds LP):", address(setup));
        setup.setup(true);
        console.log("pool initialized + liquidity seeded");

        vm.stopBroadcast();
    }
}
