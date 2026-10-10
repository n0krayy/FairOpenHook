// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title FairOpenHook
/// @notice Uniswap V4 hook that makes the opening of Community Coin pools
///         manipulation-resistant. Three mechanisms, one hook:
///         1. dynamic price-impact fee  (kills zero-capital extraction economically)
///         2. circuit breaker          (kills it absolutely — reverts the swap)
///         3. opening-window wallet caps + cooldown (kills fast sniping)
/// @dev Designed for IMD's own PoolManager (0x000000000004444c5dc75cb358380d2e3de08a90).
///      Pools using this hook must be initialized with the dynamic-fee flag.
contract FairOpenHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    /// @notice IMD token — used to tell which side of the pool is the "new coin".
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    error BreakerTripped();
    error CooldownActive();
    error WalletCapExceeded();
    error OnlyPoolManager();

    struct Params {
        uint32 windowBlocks; // opening window length in blocks (suggested: 100)
        uint24 baseFee; // fee with zero impact, in pips (suggested: 3000 = 0.30%)
        uint24 maxFee; // fee ceiling, in pips (suggested: 900_000 = 90%)
        uint32 feeK; // slope: fee = baseFee + feeK * priceImpactBps (tuned 2026-10-16: 150 via attack-replay)
        uint16 breakerBps; // max price move per swap inside the window (suggested: 2500 = 25%)
        uint256 maxBuyPerWallet; // max buy notional per wallet inside window, in quote-currency units
        uint32 cooldownBlocks; // min blocks between swaps per wallet (suggested: 3)
        address treasury; // receives the harvested fee surcharge (TODO: wire to IMD flywheel)
    }

    Params public params;

    /// @notice block number at which each pool was initialized (0 = unknown pool)
    mapping(PoolId => uint256) public openBlock;
    /// @notice sqrtPriceX96 at initialization
    mapping(PoolId => uint160) public openPrice;
    /// @notice rolling reference price for the circuit breaker (last settled sqrtPriceX96)
    mapping(PoolId => uint160) public lastPrice;
    /// @notice cumulative buy volume per wallet inside the opening window
    mapping(PoolId => mapping(address => uint256)) public boughtInWindow;
    /// @notice last swap block per wallet (cooldown)
    mapping(PoolId => mapping(address => uint256)) public lastSwapBlock;
    /// @notice fee surcharge accrued to the hook per pool & currency (as ERC6909 claims; redeemable via harvest)
    mapping(PoolId => mapping(Currency => uint256)) public surchargeAccrued;

    constructor(IPoolManager _poolManager, Params memory _params) BaseHook(_poolManager) {
        require(_params.maxFee >= _params.baseFee, "maxFee < baseFee");
        require(_params.maxFee <= 1_000_000, "maxFee > 100%");
        require(_params.breakerBps <= 10_000, "breakerBps > 100%");
        params = _params;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // beforeInitialize — record the opening of the pool
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        openBlock[id] = block.number;
        openPrice[id] = sqrtPriceX96;
        lastPrice[id] = sqrtPriceX96;
        return this.beforeInitialize.selector;
    }

    // -------------------------------------------------------------------------
    // beforeSwap — dynamic fee + opening-window caps/cooldown
    //
    // Fee split: LPs always receive exactly baseFee (via the fee override).
    // The dynamic surcharge (totalFee - baseFee) is captured by the hook on
    // exact-input swaps:
    //   1. hook mints S ERC6909 claims to itself  (hook delta: -S)
    //   2. hook returns +S specified delta        (hook delta: +S -> net zero)
    // The claims are redeemed for the underlying tokens at harvest time.
    // Using mint (not take) means no manager token balance is required up
    // front — this works on single-sided / empty pools where take would revert.
    // Exact-output swaps: surcharge stays with LPs (v1 limitation — the
    // extraction patterns we target are exact-input).
    // -------------------------------------------------------------------------

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata swapParams, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        // NOTE: tx.origin is used for rate-limit accounting only (never for auth).
        // Correct for EOAs — including every bot observed in validation — but smart-wallet
        // (AA) users share one bucket. Documented tradeoff, see DESIGN.md 4.3.
        address trader = tx.origin;

        if (_inWindow(id)) {
            uint256 last = lastSwapBlock[id][trader];
            if (last != 0 && block.number < last + params.cooldownBlocks) {
                revert CooldownActive();
            }
            lastSwapBlock[id][trader] = block.number;

            if (_isBuy(key, swapParams)) {
                uint256 amount = _abs(swapParams.amountSpecified);
                uint256 newTotal = boughtInWindow[id][trader] + amount;
                if (newTotal > params.maxBuyPerWallet) revert WalletCapExceeded();
                boughtInWindow[id][trader] = newTotal;
            }
        }

        uint24 totalFee = _quoteFee(key, swapParams);
        BeforeSwapDelta hookDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        if (swapParams.amountSpecified < 0 && totalFee > params.baseFee) {
            uint256 surcharge = uint256(_abs(swapParams.amountSpecified)) * (totalFee - params.baseFee) / 1_000_000;
            if (surcharge > 0) {
                // saturate at int128 — purely defensive, unreachable in practice
                uint256 maxDelta = uint256(uint128(type(int128).max));
                if (surcharge > maxDelta) surcharge = maxDelta;
                Currency input = swapParams.zeroForOne ? key.currency0 : key.currency1;
                surchargeAccrued[id][input] += surcharge;
                poolManager.mint(address(this), input.toId(), surcharge);
                hookDelta = toBeforeSwapDelta(int128(int256(surcharge)), 0);
            }
        }

        return (
            this.beforeSwap.selector,
            hookDelta,
            params.baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // -------------------------------------------------------------------------
    // harvest — redeem accrued surcharge claims and route tokens to the treasury
    // (the IMD flywheel: burns / staker rewards).
    //
    // Anyone may call; the destination is immutable (set at deploy) so keepers
    // cannot divert funds. burn+take must run inside poolManager.unlock.
    // -------------------------------------------------------------------------

    function harvest(PoolKey calldata key) external {
        poolManager.unlock(abi.encode(key, params.treasury));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, address to) = abi.decode(data, (PoolKey, address));
        PoolId id = key.toId();
        _redeemSurcharge(id, key.currency0, to);
        _redeemSurcharge(id, key.currency1, to);
        return "";
    }

    function _redeemSurcharge(PoolId id, Currency currency, address to) internal {
        uint256 amount = surchargeAccrued[id][currency];
        if (amount == 0) return;
        surchargeAccrued[id][currency] = 0;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    // -------------------------------------------------------------------------
    // afterSwap — circuit breaker on the *settled* price
    // -------------------------------------------------------------------------

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (_inWindow(id)) {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
            uint256 moveBps = _priceMoveBps(sqrtPriceX96, lastPrice[id]);
            if (moveBps > params.breakerBps) revert BreakerTripped();
            lastPrice[id] = sqrtPriceX96;
        }
        return (this.afterSwap.selector, 0);
    }

    /// @notice Price move between two sqrt prices, in bps of actual price.
    /// price = (sqrtP/2^96)^2, so a sqrtPrice move of s bps ~= 2s + s^2/10000 price bps.
    /// Saturates at type(uint256).max instead of overflowing — anything that large
    /// trips the breaker anyway.
    /// @dev Uses a rolling reference (last settled price), so gradual legit price
    /// discovery across many small swaps is not blocked; only single-swap jumps are.
    /// The dynamic fee remains the defense against slow drains.
    function _priceMoveBps(uint160 sqrtP1, uint160 sqrtP0) internal pure returns (uint256) {
        if (sqrtP1 == sqrtP0) return 0;
        (uint160 hi, uint160 lo) = sqrtP1 > sqrtP0 ? (sqrtP1, sqrtP0) : (sqrtP0, sqrtP1);
        uint256 diff = hi - lo;
        if (diff > type(uint256).max / 20_000) return type(uint256).max;
        uint256 s = (diff * 10_000) / lo; // sqrtPrice move in bps
        if (s > 1_000_000) return type(uint256).max; // >100x sqrt move
        return 2 * s + (s * s) / 10_000;
    }

    // -------------------------------------------------------------------------
    // Fee math — dynamic price-impact fee
    // -------------------------------------------------------------------------

    /// @notice Quotes the LP fee for a swap: baseFee + feeK * priceImpactBps, capped at maxFee.
    function _quoteFee(PoolKey calldata key, SwapParams calldata swapParams) internal view returns (uint24) {
        return _feeForImpact(_estimateImpactBps(key, swapParams));
    }

    /// @notice Pure fee curve. Saturates at maxFee instead of overflowing.
    function _feeForImpact(uint256 impactBps) internal view returns (uint24) {
        uint256 base = params.baseFee;
        if (params.feeK == 0 || impactBps == 0) return uint24(base);
        uint256 maxSurcharge = uint256(params.maxFee) - base;
        uint256 surcharge =
            impactBps > maxSurcharge / params.feeK ? maxSurcharge : uint256(params.feeK) * impactBps;
        return uint24(base + surcharge);
    }

    /// @notice Estimates the swap's price impact in bps from current pool state.
    /// Linear approximation: |amount| / virtualReserve * 10_000, where the virtual
    /// reserve is derived from active liquidity L at the current tick:
    ///   zeroForOne (selling token0): reserve0 = L * 2^96 / sqrtPriceX96
    ///   oneForZero  (selling token1): reserve1 = L * sqrtPriceX96 / 2^96
    /// @dev For exact-output swaps amountSpecified is the *output* amount, so the
    /// ratio mixes output size against input-side depth — acceptable for a fee input;
    /// the circuit breaker (afterSwap) measures the exact settled move.
    /// Returns type(uint256).max when the pool has no active liquidity: the opening
    /// tick of Community Coin pools is empirically near-empty, and any swap there is
    /// treated as maximally impactful -> maxFee. This makes the unsafe opening state
    /// unexploitable; the fee falls automatically as LPs add in-range depth.
    function _estimateImpactBps(PoolKey calldata key, SwapParams calldata swapParams)
        internal
        view
        returns (uint256)
    {
        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, id);
        if (liquidity == 0) return type(uint256).max;
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);

        uint256 reserve = swapParams.zeroForOne
            ? (uint256(liquidity) << 96) / sqrtPriceX96
            : (uint256(liquidity) * sqrtPriceX96) >> 96;
        if (reserve == 0) return type(uint256).max;

        uint256 amount = _abs(swapParams.amountSpecified);
        if (amount > type(uint256).max / 10_000) return type(uint256).max;
        return (amount * 10_000) / reserve;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _inWindow(PoolId id) internal view returns (bool) {
        uint256 opened = openBlock[id];
        return opened != 0 && block.number < opened + params.windowBlocks;
    }

    /// @notice true when the swapper is buying the new (non-IMD) token.
    /// @dev zeroForOne=true means the swapper GIVES token0 and RECEIVES token1,
    /// so "buying the new token" = receiving it = !zeroForOne when it is token0.
    function _isBuy(PoolKey calldata key, SwapParams calldata p) internal pure returns (bool) {
        // Assumes the pool pairs IMD with exactly one new token.
        bool newTokenIs0 = Currency.unwrap(key.currency0) != IMD;
        return newTokenIs0 ? !p.zeroForOne : p.zeroForOne;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }
}
