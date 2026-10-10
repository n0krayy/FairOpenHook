// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FairOpenHook} from "./FairOpenHook.sol";

/// @title FairLaunchToken
/// @notice Minimal fixed-supply ERC20 for demo launches (1B, 18 decimals).
/// @dev Demo only — the real IMD flow deploys the token through its own factory.
contract FairLaunchToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        totalSupply = 1_000_000_000 ether;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title FairLaunchFactory
/// @notice Demo factory mimicking IMD's Community Coins launch flow, with FairOpenHook attached:
///         deploy token (1B) -> deploy hook (CREATE2, mined salt) -> init pool ->
///         seed single-sided liquidity (e.g. 900M = 90%) -> remainder to launcher.
/// @dev PRODUCTION WARNING: launch() is permissionless (anyone can launch any token).
///      A production version needs access control (allowlist / staking / fees),
///      a MerkleDistributor allocation (real flow: 10%), and slippage/deadline guards.
contract FairLaunchFactory {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    int24 public constant TICK_SPACING = 60;

    event LaunchCreated(
        address indexed token, PoolId indexed poolId, address indexed hook, address launcher
    );

    error BadRange();
    error NotPoolManager();

    struct LaunchParams {
        string name;
        string symbol;
        Currency pairCurrency; // IMD on mainnet; mock in tests (must be ERC20, not native)
        FairOpenHook.Params hookParams;
        bytes32 hookSalt; // mined off-chain: HookMiner.find(address(this), FLAGS, type(FairOpenHook).creationCode, abi.encode(manager, hookParams))
        uint160 sqrtPriceX96; // opening price
        uint256 seedAmount; // new-token amount seeded as single-sided liquidity (e.g. 900M ether)
        int24 rangeGap; // ticks between current tick and the seed range (>= TICK_SPACING)
        int24 rangeWidth; // seed range width in ticks (multiple of TICK_SPACING)
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Launch a new token with FairOpenHook attached.
    /// @return token the deployed FairLaunchToken
    /// @return key the initialized PoolKey
    /// @return hook the deployed FairOpenHook
    function launch(LaunchParams calldata p)
        external
        returns (FairLaunchToken token, PoolKey memory key, FairOpenHook hook)
    {
        if (p.rangeGap < TICK_SPACING || p.rangeWidth <= 0 || p.rangeWidth % TICK_SPACING != 0) {
            revert BadRange();
        }

        // 1. deploy the token (1B supply -> this factory)
        token = new FairLaunchToken(p.name, p.symbol);
        Currency tokenCurrency = Currency.wrap(address(token));

        // 2. deploy the hook via CREATE2 with the caller-mined salt.
        // NOTE: the hook constructor itself validates the address flags
        // (BaseHook -> Hooks.validateHookPermissions), so a bad salt reverts here.
        hook = new FairOpenHook{salt: p.hookSalt}(poolManager, p.hookParams);

        // 3. sort currencies, build the key (dynamic fee -> hook sets the fee)
        (Currency c0, Currency c1) = Currency.unwrap(tokenCurrency) < Currency.unwrap(p.pairCurrency)
            ? (tokenCurrency, p.pairCurrency)
            : (p.pairCurrency, tokenCurrency);
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // 4. initialize the pool (fires hook.beforeInitialize -> window bookkeeping)
        poolManager.initialize(key, p.sqrtPriceX96);

        // 5. seed single-sided liquidity: range placed out-of-range on the new-token side
        int24 currentTick = TickMath.getTickAtSqrtPrice(p.sqrtPriceX96);
        int24 lower;
        int24 upper;
        uint128 liquidity;
        if (c0 == tokenCurrency) {
            // token0-only: range above current tick
            lower = _alignUp(currentTick + p.rangeGap, TICK_SPACING);
            upper = lower + p.rangeWidth;
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), p.seedAmount
            );
        } else {
            // token1-only: range below current tick
            upper = _alignDown(currentTick - p.rangeGap, TICK_SPACING);
            lower = upper - p.rangeWidth;
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), p.seedAmount
            );
        }
        if (lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK) revert BadRange();

        poolManager.unlock(
            abi.encode(
                key,
                ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: upper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: 0
                })
            )
        );

        // 6. remainder of the 1B supply goes to the launcher
        // (real IMD flow: 10% -> MerkleDistributor, 0% -> launcher — demo simplification)
        uint256 remainder = token.balanceOf(address(this));
        if (remainder > 0) token.transfer(msg.sender, remainder);

        emit LaunchCreated(address(token), key.toId(), address(hook), msg.sender);
    }

    /// @notice PoolManager unlock callback: adds the seeded liquidity and settles.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, ModifyLiquidityParams memory mlp) =
            abi.decode(data, (PoolKey, ModifyLiquidityParams));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, mlp, "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 deltaAmount) internal {
        if (deltaAmount >= 0) {
            // manager owes us (not expected when seeding) — take it
            if (deltaAmount > 0) {
                poolManager.take(currency, address(this), uint256(int256(deltaAmount)));
            }
            return;
        }
        uint256 owed = uint256(int256(-deltaAmount));
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(poolManager), owed);
        poolManager.settle();
    }

    function _alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r == 0) return tick;
        return r > 0 ? tick + (spacing - r) : tick - r;
    }

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r == 0) return tick;
        return r > 0 ? tick - r : tick - (spacing + r);
    }
}
