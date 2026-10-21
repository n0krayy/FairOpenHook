// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal Uniswap V4 swap router for the FairOpenHook testnet demo.
/// @dev Supports exact-input swaps only. Caller must approve this router for the input token.
contract DemoRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    struct CallbackData {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Swap exact input tokens. Pulls input from msg.sender, sends output to msg.sender.
    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta delta)
    {
        bytes memory data = abi.encode(
            CallbackData({
                key: key,
                params: SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                payer: msg.sender
            })
        );
        delta = abi.decode(poolManager.unlock(data), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only manager");
        CallbackData memory cb = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.swap(cb.key, cb.params, "");

        // settle input (negative delta = owed to pool), take output
        (Currency input, Currency output) = cb.params.zeroForOne
            ? (cb.key.currency0, cb.key.currency1)
            : (cb.key.currency1, cb.key.currency0);

        int256 inputDelta = cb.params.zeroForOne ? delta.amount0() : delta.amount1();
        int256 outputDelta = cb.params.zeroForOne ? delta.amount1() : delta.amount0();

        // pay input tokens into the pool (sync + transfer + settle pattern)
        uint256 owed = uint256(-inputDelta);
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).transferFrom(cb.payer, address(poolManager), owed);
        poolManager.settle();

        // take output tokens to the payer
        uint256 out = uint256(outputDelta);
        poolManager.take(output, cb.payer, out);

        return abi.encode(delta);
    }
}
