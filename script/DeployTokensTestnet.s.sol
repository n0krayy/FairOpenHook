// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Phase 1 of testnet demo setup: deploys the quote token (tIMD, stands
///         in for IMD on testnet) and the demo Community Coin.
/// @dev Run on Robinhood Testnet (46630). Prints both addresses — feed the
///      quote token address into MineSaltTestnet, then run DeployTestnet.
///      forge script script/DeployTokensTestnet.s.sol --rpc-url <testnet> --broadcast
contract DeployTokensTestnet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        MockERC20 quote = new MockERC20("Test IMD", "tIMD", 18);
        MockERC20 coin = new MockERC20("Demo Community Coin", "DCC", 18);

        vm.stopBroadcast();

        console.log("tIMD (quote):", address(quote));
        console.log("DCC (demo coin):", address(coin));
    }
}
