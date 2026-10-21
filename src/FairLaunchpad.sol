// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Production launchpad: lets anyone launch a Community Coin with
///         FairOpenHook protection in one transaction.
/// @dev Uses the SHARED hook deployment (hooks are per-pool, one hook serves all pools).
///      Launcher provides IMD; the launchpad mints the new token, creates the
///      pool, and seeds liquidity. Remaining new tokens go to the launcher.
contract FairLaunchpad is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    address public immutable hook;
    address public immutable quoteToken; // IMD on Robinhood Chain

    event Launched(address indexed token, PoolId indexed poolId, address indexed launcher);

    struct SeedArgs {
        PoolKey key;
        address token;
        uint256 quoteAmount;
        uint256 tokenAmount;
        int24 tickLower;
        int24 tickUpper;
    }

    SeedArgs private _pending;

    constructor(IPoolManager _poolManager, address _hook, address _quoteToken) {
        poolManager = _poolManager;
        hook = _hook;
        quoteToken = _quoteToken;
    }

    /// @notice Launch a new protected token.
    /// @param name Token name, @param symbol Token symbol,
    /// @param quoteAmount tIMD the launcher provides for seeding,
    /// @param sqrtPriceX96 Opening price (token per tIMD, as sqrtPriceX96).
    ///        Launcher must approve this contract for quoteAmount tIMD first.
    function launch(string calldata name, string calldata symbol, uint256 quoteAmount, uint160 sqrtPriceX96)
        external
        returns (address token, PoolId poolId)
    {
        // 1. deploy the new token (1B supply to this contract)
        MockERC20 coin = new MockERC20(name, symbol, 18);
        token = address(coin);
        coin.mint(address(this), 1_000_000_000 ether);

        // 2. sort currencies, build key
        (Currency c0, Currency c1) =
            quoteToken < token ? (Currency.wrap(quoteToken), Currency.wrap(token)) : (Currency.wrap(token), Currency.wrap(quoteToken));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = key.toId();

        // 3. pull tIMD from launcher
        IERC20(quoteToken).transferFrom(msg.sender, address(this), quoteAmount);

        // 4. initialize + seed via unlock (ticks ±600 around opening price)
        poolManager.initialize(key, sqrtPriceX96);
        int24 baseTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // round to tick spacing
        int24 tickLower = (baseTick - 600) / 60 * 60;
        int24 tickUpper = (baseTick + 600) / 60 * 60;
        _pending = SeedArgs({
            key: key,
            token: token,
            quoteAmount: quoteAmount,
            tokenAmount: 1_000_000_000 ether,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        poolManager.unlock("");

        // 5. send remaining new tokens to launcher
        uint256 leftover = coin.balanceOf(address(this));
        if (leftover > 0) coin.transfer(msg.sender, leftover);

        emit Launched(token, poolId, msg.sender);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only manager");
        SeedArgs memory s = _pending;
        delete _pending;

        // how much of each the 1e24 liquidity needs (capped by what we hold)
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            s.key,
            ModifyLiquidityParams({tickLower: s.tickLower, tickUpper: s.tickUpper, liquidityDelta: 4e23, salt: bytes32(0)}),
            ""
        );

        uint256 need0 = callerDelta.amount0() < 0 ? uint256(uint128(-callerDelta.amount0())) : 0;
        uint256 need1 = callerDelta.amount1() < 0 ? uint256(uint128(-callerDelta.amount1())) : 0;

        if (need0 > 0) {
            poolManager.sync(s.key.currency0);
            IERC20(Currency.unwrap(s.key.currency0)).transfer(address(poolManager), need0);
            poolManager.settle();
        }
        if (need1 > 0) {
            poolManager.sync(s.key.currency1);
            IERC20(Currency.unwrap(s.key.currency1)).transfer(address(poolManager), need1);
            poolManager.settle();
        }
        return "";
    }
}
