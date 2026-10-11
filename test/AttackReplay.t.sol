// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";

/// @notice BEFORE/AFTER attack replay on a mainnet fork (SWARMLER #1212 style).
///
/// BEFORE: opening pool recreated faithfully (900M single-sided out-of-range +
///         dust in-range, no hook) — a 118.88 IMD dust buy manipulates the price.
/// AFTER:  identical pool + FairOpenHook — the same attack reverts.
///
/// [FAKTA] = from on-chain data (~/workspace/imd-validation/LAPORAN.md)
/// [REKREASI] = faithful recreation executed on the fork (numbers from execution)
contract AttackReplay is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address constant PM_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90; // IMD's PoolManager [FAKTA]
    address constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7; // $IMD [FAKTA]
    address constant ATTACKER = 0xd8ba9E5886B7000BACe2C9dbdd0BE98Ac77D4A28; // SWARMLER #1212 attacker EOA [FAKTA]

    uint256 constant FORK_BLOCK = 26158808; // SWARMLER #1212 launch block [FAKTA]
    uint256 constant ATTACK_IN = 118.88 ether; // real attack swap-1 IMD input [FAKTA]
    uint24 constant REAL_POOL_FEE = 12500; // 1.25% pool fee [FAKTA]
    // 900M placed FAR from the opening tick (100k ticks): the real launch's
    // single-sided liquidity was not in the buy's path at the opening tick,
    // which is why dust moved the price 121M-x [FAKTA: "tick pembuka hampir tanpa likuiditas"]
    int24 constant RANGE_DIST = 100020;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    IPoolManager pm;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    MockERC20 newToken;
    Currency c0;
    Currency c1;
    bool newTokenIs0;
    int24 initTick;
    PoolSwapTest.TestSettings settings;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        pm = IPoolManager(PM_ADDR);
        swapRouter = new PoolSwapTest(pm);
        liqRouter = new PoolModifyLiquidityTest(pm);
        settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        newToken = new MockERC20("ReplayToken", "RPL", 18);
        newToken.mint(address(this), 1_000_000_000 ether);

        address mockAddr = address(newToken);
        newTokenIs0 = mockAddr < IMD_ADDR;
        (c0, c1) = newTokenIs0
            ? (Currency.wrap(mockAddr), Currency.wrap(IMD_ADDR))
            : (Currency.wrap(IMD_ADDR), Currency.wrap(mockAddr));
        // opening price 2.5e-6 IMD/token [FAKTA]
        initTick = newTokenIs0 ? int24(-129000) : int24(129000);

        // fund attacker (real EOA) + self (for liquidity seeding)
        deal(IMD_ADDR, ATTACKER, 1000 ether);
        deal(IMD_ADDR, address(this), 10_000 ether);
        vm.deal(ATTACKER, 10 ether);

        newToken.approve(address(liqRouter), type(uint256).max);
        newToken.approve(address(swapRouter), type(uint256).max);
        IERC20(IMD_ADDR).approve(address(liqRouter), type(uint256).max);
        IERC20(IMD_ADDR).approve(address(swapRouter), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Pool builders
    // ------------------------------------------------------------------

    /// @notice Builds the SWARMLER-style opening pool: 900M single-sided
    /// out-of-range + dust in-range. [REKREASI]
    function _buildOpeningPool(IHooks hooks, uint24 fee, uint128 dustLiq)
        internal
        returns (PoolKey memory key, PoolId id)
    {
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: 60, hooks: hooks});
        id = key.toId();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        // 900M new tokens single-sided, FAR out of range [FAKTA: 90% of 1B supply]
        // Placed ~100k ticks away so the opening-tick buy walks through emptiness,
        // replicating the real "tick pembuka hampir tanpa likuiditas".
        uint256 amount900M = 900_000_000 ether;
        if (newTokenIs0) {
            // token0-only position far above current price
            int24 tA = initTick + RANGE_DIST;
            int24 tB = initTick + RANGE_DIST + 6000;
            uint128 liq = _liqForAmount0(
                TickMath.getSqrtPriceAtTick(tA), TickMath.getSqrtPriceAtTick(tB), amount900M
            );
            liqRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tA,
                    tickUpper: tB,
                    liquidityDelta: int256(uint256(liq)),
                    salt: 0
                }),
                ""
            );
        } else {
            // token1-only position far below current price
            int24 tA = initTick - RANGE_DIST - 6000;
            int24 tB = initTick - RANGE_DIST;
            uint128 liq = _liqForAmount1(
                TickMath.getSqrtPriceAtTick(tA), TickMath.getSqrtPriceAtTick(tB), amount900M
            );
            liqRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tA,
                    tickUpper: tB,
                    liquidityDelta: int256(uint256(liq)),
                    salt: 0
                }),
                ""
            );
        }

        // dust in-range: replicates the near-zero opening liquidity [FAKTA]
        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: initTick - 60,
                tickUpper: initTick + 60,
                liquidityDelta: int256(uint256(dustLiq)),
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    /// @notice Dust liquidity sized for ~1e-8 IMD of in-range depth
    /// (tuned to replicate the real attack's 121M-x swing [FAKTA]).
    function _dustLiq() internal view returns (uint128) {
        uint160 sqrtC = TickMath.getSqrtPriceAtTick(initTick);
        if (newTokenIs0) {
            // IMD is token1: amount1 = L * (sqrtC - sqrtL) / 2^96
            uint160 sqrtL = TickMath.getSqrtPriceAtTick(initTick - 60);
            return uint128(FullMath.mulDiv(1e10, 1 << 96, sqrtC - sqrtL));
        } else {
            // IMD is token0: amount0 = L * (sqrtU - sqrtC) * 2^96 / (sqrtC * sqrtU)
            uint160 sqrtU = TickMath.getSqrtPriceAtTick(initTick + 60);
            uint256 prod = FullMath.mulDiv(sqrtC, sqrtU, 1 << 96);
            return uint128(FullMath.mulDiv(1e10, prod, sqrtU - sqrtC));
        }
    }

    function _liqForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        uint256 prod = FullMath.mulDiv(sqrtA, sqrtB, 1 << 96);
        return uint128(FullMath.mulDiv(amount0, prod, sqrtB - sqrtA));
    }

    function _liqForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtB - sqrtA));
    }

    function _deployHook() internal returns (FairOpenHook hook) {
        FairOpenHook.Params memory p = FairOpenHook.Params({
            windowBlocks: 100,
            baseFee: 3_000,
            maxFee: 900_000,
            feeK: 150,
            breakerBps: 2_500,
            maxBuyPerWallet: 4_500_000 ether,
            cooldownBlocks: 3,
            treasury: address(this),
            pairToken: IMD_ADDR
        });
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), FLAGS, type(FairOpenHook).creationCode, abi.encode(address(pm), p)
        );
        hook = new FairOpenHook{salt: salt}(pm, p);
        require(address(hook) == hookAddr, "hook addr mismatch");
    }

    // ------------------------------------------------------------------
    // The attack: 118.88 IMD exact-input buy of the new token [FAKTA]
    // ------------------------------------------------------------------

    function _attackSwapParams() internal view returns (SwapParams memory) {
        // buy new token with IMD
        bool zeroForOne = newTokenIs0 ? false : true;
        uint160 limit = newTokenIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(ATTACK_IN),
            sqrtPriceLimitX96: limit
        });
    }

    function _tokensOut(BalanceDelta d) internal view returns (uint256) {
        int128 amt = newTokenIs0 ? d.amount0() : d.amount1();
        return amt > 0 ? uint256(int256(amt)) : 0;
    }

    /// @notice (priceAfter/priceBefore) scaled by 1e6 ("micro-x").
    function _swingMicroX(uint160 sBefore, uint160 sAfter) internal pure returns (uint256) {
        (uint256 num, uint256 den) =
            sAfter >= sBefore ? (uint256(sAfter), uint256(sBefore)) : (uint256(sBefore), uint256(sAfter));
        uint256 q = num / den;
        uint256 r = num % den;
        return q * q * 1e6 + (2 * q * r * 1e6) / den + ((r * 1e6) / den * r) / den;
    }

    // ------------------------------------------------------------------
    // BEFORE: no hook — the attack works
    // ------------------------------------------------------------------

    function test_before_attackSucceeds() public {
        (PoolKey memory key, PoolId id) = _buildOpeningPool(IHooks(address(0)), REAL_POOL_FEE, _dustLiq());
        vm.roll(block.number + 1); // block+1, like the real attack [FAKTA]

        (uint160 sBefore,,,) = StateLibrary.getSlot0(pm, id);

        vm.startPrank(ATTACKER);
        IERC20(IMD_ADDR).approve(address(swapRouter), type(uint256).max);
        BalanceDelta delta = swapRouter.swap(key, _attackSwapParams(), settings, "");
        vm.stopPrank();

        (uint160 sAfter,,,) = StateLibrary.getSlot0(pm, id);
        uint256 out = _tokensOut(delta);
        uint256 swing = _swingMicroX(sBefore, sAfter);
        uint256 feePaid = (ATTACK_IN * REAL_POOL_FEE) / 1_000_000;

        console.log("=== BEFORE (no hook) ===");
        console.log("attack input (IMD):", ATTACK_IN);
        console.log("tokens extracted:", out);
        console.log("price swing micro-x:", swing);
        console.log("fee paid (IMD):", feePaid);
        console.log("sqrtPrice before:", uint256(sBefore));
        console.log("sqrtPrice after:", uint256(sAfter));

        assertGt(swing, 1e6, "expected massive price swing");
    }

    // ------------------------------------------------------------------
    // AFTER: with FairOpenHook — the attack reverts
    // ------------------------------------------------------------------

    function test_after_attackBlocked() public {
        FairOpenHook hook = _deployHook();
        (PoolKey memory key,) = _buildOpeningPool(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, _dustLiq());
        vm.roll(block.number + 1);

        vm.startPrank(ATTACKER);
        IERC20(IMD_ADDR).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swap(key, _attackSwapParams(), settings, "");
        vm.stopPrank();

        console.log("=== AFTER (FairOpenHook) ===");
        console.log("attack reverted as expected");
    }

    // ------------------------------------------------------------------
    // AFTER: fee curve on a healthy hooked pool (feeK tuning data)
    // ------------------------------------------------------------------

    function test_after_feeCurve() public {
        FairOpenHook hook = _deployHook();
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        // healthy two-sided liquidity: 10M new tokens + equivalent IMD
        // (at 2.5e-6 IMD/token, 10M tokens ~= 25 IMD)
        uint256 tokAmt = 10_000_000 ether;
        int24 tA = initTick - 600;
        int24 tB = initTick + 600;
        uint128 liq;
        if (newTokenIs0) {
            // need token0 amount for [tA,tB] containing current tick: use amount0 side
            // approximate with full-range-ish: compute from token0
            liq = _liqForAmount0(
                TickMath.getSqrtPriceAtTick(tA), TickMath.getSqrtPriceAtTick(initTick), tokAmt
            );
        } else {
            liq = _liqForAmount1(
                TickMath.getSqrtPriceAtTick(initTick), TickMath.getSqrtPriceAtTick(tB), tokAmt
            );
        }
        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tA, tickUpper: tB, liquidityDelta: int256(uint256(liq)), salt: 0}),
            ""
        );
        vm.roll(block.number + 1);

        console.log("=== FEE CURVE (healthy hooked pool, feeK=150) ===");
        // swap sizes: 0.1, 0.5, 1.0, 2.0 IMD
        uint256[4] memory sizes = [uint256(0.1 ether), uint256(0.5 ether), uint256(1 ether), uint256(2 ether)];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 accruedBefore = hook.surchargeAccrued(id, newTokenIs0 ? c1 : c0);
            bool zeroForOne = newTokenIs0 ? false : true;
            uint160 limit = newTokenIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
            vm.startPrank(ATTACKER);
            IERC20(IMD_ADDR).approve(address(swapRouter), type(uint256).max);
            try swapRouter.swap(
                key,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(sizes[i]), sqrtPriceLimitX96: limit}),
                settings,
                ""
            ) {
                uint256 surcharge = hook.surchargeAccrued(id, newTokenIs0 ? c1 : c0) - accruedBefore;
                uint256 feePips = (surcharge * 1_000_000) / sizes[i];
                console.log("swap IMD in:", sizes[i]);
                console.log("  fee pips:", feePips);
            } catch {
                console.log("swap IMD in:", sizes[i]);
                console.log("  REVERTED");
            }
            vm.stopPrank();
            vm.roll(block.number + 4); // avoid cooldown between probes
        }
    }

    // ------------------------------------------------------------------
    // Positive control: small legit swap on hooked pool passes
    // ------------------------------------------------------------------

    function test_legitSwapPasses() public {
        FairOpenHook hook = _deployHook();
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        uint256 tokAmt = 10_000_000 ether;
        int24 tA = initTick - 600;
        int24 tB = initTick + 600;
        uint128 liq;
        if (newTokenIs0) {
            liq = _liqForAmount0(
                TickMath.getSqrtPriceAtTick(tA), TickMath.getSqrtPriceAtTick(initTick), tokAmt
            );
        } else {
            liq = _liqForAmount1(
                TickMath.getSqrtPriceAtTick(initTick), TickMath.getSqrtPriceAtTick(tB), tokAmt
            );
        }
        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tA, tickUpper: tB, liquidityDelta: int256(uint256(liq)), salt: 0}),
            ""
        );
        vm.roll(block.number + 1);

        // legit small buy: 0.01 IMD
        bool zeroForOne = newTokenIs0 ? false : true;
        uint160 limit = newTokenIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        uint256 accruedBefore = hook.surchargeAccrued(id, newTokenIs0 ? c1 : c0);

        vm.startPrank(ATTACKER);
        IERC20(IMD_ADDR).approve(address(swapRouter), type(uint256).max);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: limit}),
            settings,
            ""
        );
        vm.stopPrank();

        uint256 surcharge = hook.surchargeAccrued(id, newTokenIs0 ? c1 : c0) - accruedBefore;
        uint256 feePips = (surcharge * 1_000_000) / 0.01 ether;
        uint256 out = _tokensOut(delta);

        console.log("=== LEGIT SWAP (0.01 IMD on healthy hooked pool) ===");
        console.log("succeeded, tokens out:", out);
        console.log("fee pips:", feePips);

        assertGt(out, 0, "legit swap got nothing");
        assertLe(feePips, 10_000, "fee too high for small swap"); // <= 1%
    }
}
