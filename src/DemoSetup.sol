// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice One-shot testnet demo setup: initializes a V4 pool with FairOpenHook
///         and seeds in-range liquidity. Token addresses must be pre-sorted
///         (token0 < token1). Mints its own tokens via public MockERC20.mint.
contract DemoSetup is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager public immutable poolManager;
    PoolKey public key;
    uint256 public seed0;
    uint256 public seed1;
    uint160 public sqrtPriceX96;
    bool public initialized;
    int24 public tickLower;
    int24 public tickUpper;

    constructor(
        IPoolManager _poolManager,
        address token0,
        address token1,
        address hook,
        uint160 _sqrtPrice,
        uint256 amount0,
        uint256 amount1,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        require(token0 < token1, "sort tokens");
        poolManager = _poolManager;
        seed0 = amount0;
        seed1 = amount1;
        sqrtPriceX96 = _sqrtPrice;
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        MockERC20(token0).mint(address(this), amount0);
        MockERC20(token1).mint(address(this), amount1);
    }

    /// @notice Initializes the pool (if needed) and seeds liquidity. Call once after deployment.
    /// @param doInit Set false if the pool was already initialized (e.g. re-seeding).
    function setup(bool doInit) external {
        require(!initialized, "done");
        initialized = true;
        if (doInit) poolManager.initialize(key, sqrtPriceX96);
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only manager");

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 4e23, salt: bytes32(0)}),
            ""
        );

        uint256 amt0 = callerDelta.amount0() < 0 ? uint256(uint128(-callerDelta.amount0())) : 0;
        uint256 amt1 = callerDelta.amount1() < 0 ? uint256(uint128(-callerDelta.amount1())) : 0;

        if (amt0 > 0) {
            poolManager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), amt0);
            poolManager.settle();
        }
        if (amt1 > 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), amt1);
            poolManager.settle();
        }
        return "";
    }
}
