// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";
import {FairOpenHookHarness} from "./FairOpenHookHarness.sol";

contract FairOpenHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    FairOpenHook hook;
    FairOpenHookHarness harness;
    PoolId poolId;
    PoolKey wideKey;
    PoolId wideId;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function _defaultParams() internal pure returns (FairOpenHook.Params memory) {
        return FairOpenHook.Params({
            windowBlocks: 100,
            baseFee: 3_000, // 0.30%
            maxFee: 900_000, // 90%
            feeK: 150, // 10% impact -> +15% fee (tuned 2026-10-10 via attack-replay: must exceed impact to kill sub-breaker manipulation)
            breakerBps: 2_500, // 25%
            maxBuyPerWallet: 4_500_000 ether,
            cooldownBlocks: 3,
            treasury: address(0)
        });
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        FairOpenHook.Params memory p = _defaultParams();

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), FLAGS, type(FairOpenHook).creationCode, abi.encode(address(manager), p)
        );
        hook = new FairOpenHook{salt: salt}(IPoolManager(address(manager)), p);
        assertEq(address(hook), hookAddr, "hook address mismatch");

        (address harnessAddr, bytes32 harnessSalt) = HookMiner.find(
            address(this), FLAGS, type(FairOpenHookHarness).creationCode, abi.encode(address(manager), p)
        );
        harness = new FairOpenHookHarness{salt: harnessSalt}(IPoolManager(address(manager)), p);
        assertEq(address(harness), harnessAddr, "harness address mismatch");

        (key, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        // second pool with wide-range liquidity for breaker tests:
        // a single swap must be *able* to move the price >25% for the trip test.
        // NOTE: needs its own currency pair — PoolKey (incl. hook) must differ.
        (Currency w0, Currency w1) = deployMintAndApprove2Currencies();
        (wideKey, wideId) = initPool(
            w0, w1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity(
            wideKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ------------------------------------------------------------------
    // Deployment / permissions
    // ------------------------------------------------------------------

    function test_hookHasExpectedPermissions() public view {
        IHooks h = IHooks(address(hook));
        assertTrue(Hooks.hasPermission(h, Hooks.BEFORE_INITIALIZE_FLAG));
        assertTrue(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(h, Hooks.AFTER_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.AFTER_INITIALIZE_FLAG));
    }

    function test_paramsStored() public view {
        (
            uint32 windowBlocks,
            uint24 baseFee,
            ,
            ,
            ,
            ,
            ,

        ) = hook.params();
        assertEq(windowBlocks, 100);
        assertEq(baseFee, 3_000);
    }

    // ------------------------------------------------------------------
    // Fee curve (pure math)
    // ------------------------------------------------------------------

    function test_feeForImpact_zero() public view {
        assertEq(harness.exposedFeeForImpact(0), 3_000, "zero impact -> baseFee");
    }

    function test_feeForImpact_scalesLinearly() public view {
        // feeK=150: 1000 bps impact -> 3000 + 150*1000 = 153_000 pips (15.3%)
        assertEq(harness.exposedFeeForImpact(1_000), 153_000);
    }

    function test_feeForImpact_capsAtMaxFee() public view {
        assertEq(harness.exposedFeeForImpact(type(uint256).max), 900_000, "saturates, never reverts");
        // (900000 - 3000) / 150 = 5980 bps is exactly the cap
        assertEq(harness.exposedFeeForImpact(5_980), 900_000);
        assertEq(harness.exposedFeeForImpact(5_981), 900_000);
        assertEq(harness.exposedFeeForImpact(5_979), 899_850);
    }

    // ------------------------------------------------------------------
    // Impact estimation against real pool state
    // ------------------------------------------------------------------

    function test_estimateImpact_matchesHandComputation() public view {
        uint128 liquidity = StateLibrary.getLiquidity(manager, poolId);
        assertGt(liquidity, 0, "pool has no liquidity");

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 impact = harness.exposedEstimateImpactBps(key, swapParams);

        // hand computation: reserve0 = L * 2^96 / sqrtPriceX96; impact = amount * 10000 / reserve
        uint256 expectedReserve = (uint256(liquidity) << 96) / SQRT_PRICE_1_1;
        uint256 expected = (1 ether * 10_000) / expectedReserve;
        assertEq(impact, expected, "impact estimate mismatch");
        assertGt(impact, 0, "impact should be positive");
    }

    function test_estimateImpact_doublesWithSize() public view {
        SwapParams memory small_ = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        SwapParams memory big = SwapParams({
            zeroForOne: true,
            amountSpecified: -2 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        uint256 impactSmall = harness.exposedEstimateImpactBps(key, small_);
        uint256 impactBig = harness.exposedEstimateImpactBps(key, big);
        assertEq(impactBig, impactSmall * 2, "impact must scale linearly with size");
    }

    // ------------------------------------------------------------------
    // beforeSwap wiring
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // beforeSwap wiring — fee split
    // ------------------------------------------------------------------

    function test_beforeSwap_splitsFee_lPsGetBase_surchargeToHook() public {
        // via a real swap (direct beforeSwap calls can't mint outside unlock)
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        uint256 impact = harness.exposedEstimateImpactBps(wideKey, swapParams);
        uint24 totalFee = harness.exposedFeeForImpact(impact);
        uint256 expectedSurcharge = (0.01 ether * (uint256(totalFee) - 3_000)) / 1_000_000;
        assertGt(expectedSurcharge, 0, "test setup: expected zero surcharge");

        _swap(wideKey, swapParams);

        // surcharge accrued as ERC6909 claims on the hook
        assertEq(
            hook.surchargeAccrued(wideId, wideKey.currency0),
            expectedSurcharge,
            "surcharge accrual mismatch"
        );
        assertEq(
            manager.balanceOf(address(hook), wideKey.currency0.toId()),
            expectedSurcharge,
            "hook claim balance mismatch"
        );
    }

    function test_beforeSwap_noSurcharge_exactOutput() public {
        // v1: exact-output swaps keep the full fee with LPs (documented limitation)
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // exact output
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(address(this), key, swapParams, "");

        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag missing");
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, 3_000, "LPs must get baseFee");
        assertEq(delta.getSpecifiedDelta(), 0, "no hook delta on exact output");
    }

    // ------------------------------------------------------------------
    // Circuit breaker
    // ------------------------------------------------------------------

    PoolSwapTest.TestSettings internal _settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function _swap(PoolKey memory k, SwapParams memory p) internal returns (BalanceDelta) {
        return swapRouter.swap(k, p, _settings, ZERO_BYTES);
    }

    function test_priceMoveBps_math() public view {
        uint160 base = SQRT_PRICE_1_1;
        assertEq(harness.exposedPriceMoveBps(base, base), 0, "no move -> 0");

        // sqrtPrice +11.8%  =>  s = 1179 bps (integer truncation)  =>  2*1179 + 1179^2/10000 = 2497 bps
        uint160 up = uint160((uint256(base) * 11180) / 10000);
        assertEq(harness.exposedPriceMoveBps(up, base), 2497, "up 11.8% sqrt -> ~25% price");

        // symmetric down move: s = 1337 bps  =>  2*1337 + 1337^2/10000 = 2852 bps
        uint160 down = uint160((uint256(base) * 8820) / 10000);
        uint256 downMove = harness.exposedPriceMoveBps(down, base);
        assertGt(downMove, 2800, "down move lower bound");
        assertLt(downMove, 2900, "down move upper bound");

        // absurd move saturates instead of overflowing
        assertEq(
            harness.exposedPriceMoveBps(type(uint160).max, 1),
            type(uint256).max,
            "absurd move saturates"
        );
    }

    function test_breaker_allowsSmallSwap() public {
        // 0.1 ether into 1e18 depth -> ~-17% price move < 25% -> passes
        _swap(
            wideKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        (uint160 settled,,,) = StateLibrary.getSlot0(manager, wideId);
        assertEq(hook.lastPrice(wideId), settled, "rolling reference not updated");
    }

    function test_breaker_tripsOnLargeSwap() public {
        // 0.3 ether into 1e18 depth -> ~-41% price move > 25% -> reverts.
        // NOTE: bare expectRevert — PoolManager wraps hook reverts (ERC-7751 style),
        // so the BreakerTripped selector is nested inside WrappedError. The paired
        // allowsSmallSwap test proves the revert comes from the breaker, not plumbing.
        vm.expectRevert();
        _swap(
            wideKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.3 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function test_breaker_usesRollingReference() public {
        // two consecutive ~-17% moves: each is under 25% vs the rolling reference,
        // so both pass. Against a fixed opening price the second would read ~-31% and trip.
        SwapParams memory p = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        _swap(wideKey, p);
        vm.roll(block.number + 10); // move past the cooldown
        _swap(wideKey, p); // must not revert
    }

    function test_breaker_inactiveAfterWindow() public {
        // past the 100-block window the breaker no longer constrains swaps
        vm.roll(block.number + 101);
        _swap(
            wideKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.3 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        ); // must not revert
    }

    // ------------------------------------------------------------------
    // Cooldown
    // ------------------------------------------------------------------

    function test_cooldown_blocksRapidSwaps() public {
        // NOTE: uses the wide pool — the narrow `key` pool's +-120 tick range
        // cannot absorb even a ~2% move without gapping into the breaker.
        SwapParams memory p = SwapParams({
            zeroForOne: false, // buy the new token (currency0 in mock pools)
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        _swap(wideKey, p); // first swap passes
        // NOTE: bare expectRevert — PoolManager wraps hook reverts (ERC-7751 style)
        vm.expectRevert();
        _swap(wideKey, p); // same block -> CooldownActive
    }

    function test_cooldown_passesAfterWait() public {
        SwapParams memory p = SwapParams({
            zeroForOne: false,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        _swap(wideKey, p);
        vm.roll(block.number + 3);
        _swap(wideKey, p); // cooldown elapsed -> passes
    }

    // ------------------------------------------------------------------
    // Wallet cap
    // ------------------------------------------------------------------

    FairOpenHook smallCap;
    PoolKey capKey;
    PoolId capId;

    /// @notice Deploys a hook with a tiny wallet cap for cap tests (mined on demand).
    function _deploySmallCapHook() internal {
        FairOpenHook.Params memory p = _defaultParams();
        p.maxBuyPerWallet = 2 ether;
        p.cooldownBlocks = 0; // isolate cap behavior from cooldown
        (address hAddr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(FairOpenHook).creationCode, abi.encode(address(manager), p));
        smallCap = new FairOpenHook{salt: salt}(IPoolManager(address(manager)), p);
        assertEq(address(smallCap), hAddr);

        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        (capKey, capId) =
            initPool(c0, c1, IHooks(address(smallCap)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            capKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e24, salt: 0}),
            ZERO_BYTES
        );
    }

    function _buy(uint256 amount) internal returns (BalanceDelta) {
        return _swap(
            capKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );
    }

    function test_cap_allowsUnderLimit() public {
        _deploySmallCapHook();
        _buy(1.5 ether);
        assertEq(smallCap.boughtInWindow(capId, tx.origin), 1.5 ether, "cap accounting wrong");
    }

    function test_cap_revertsOverLimit() public {
        _deploySmallCapHook();
        _buy(1.5 ether);
        // cumulative 2.5 ether > 2 ether cap -> reverts (wrapped WalletCapExceeded)
        vm.expectRevert();
        _buy(1 ether);
    }

    function test_cap_ignoresSells() public {
        _deploySmallCapHook();
        // SELL the new token (zeroForOne=true): must NOT count toward the buy cap,
        // even at large size. This also pins the buy-direction logic.
        _swap(
            capKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        assertEq(smallCap.boughtInWindow(capId, tx.origin), 0, "sells must not count");
        _buy(1 ether);
        assertEq(smallCap.boughtInWindow(capId, tx.origin), 1 ether);
    }

    function test_cap_liftsAfterWindow() public {
        _deploySmallCapHook();
        vm.roll(block.number + 101);
        // whale buy far above the cap: allowed once the window closed
        _buy(100 ether); // must not revert
    }

    // ------------------------------------------------------------------
    // harvest — surcharge routing to the treasury
    // ------------------------------------------------------------------

    function test_harvest_routesSurchargeToTreasury() public {
        address treasury = makeAddr("treasury");
        FairOpenHook.Params memory p = _defaultParams();
        p.treasury = treasury;
        (address hAddr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(FairOpenHook).creationCode, abi.encode(address(manager), p));
        FairOpenHook treasuryHook = new FairOpenHook{salt: salt}(IPoolManager(address(manager)), p);
        assertEq(address(treasuryHook), hAddr);

        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) =
            initPool(c0, c1, IHooks(address(treasuryHook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e24, salt: 0}), ZERO_BYTES
        );

        // swap with price impact -> surcharge accrues to the hook (input = currency0)
        // NOTE: needs enough size for impact >= 1 bps against 1e24 liquidity
        _swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1000 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        uint256 accrued = treasuryHook.surchargeAccrued(id, c0);
        assertGt(accrued, 0, "no surcharge accrued");

        uint256 before = MockERC20(Currency.unwrap(c0)).balanceOf(treasury);
        treasuryHook.harvest(k);
        uint256 received = MockERC20(Currency.unwrap(c0)).balanceOf(treasury) - before;
        assertEq(received, accrued, "treasury did not receive surcharge");
        assertEq(treasuryHook.surchargeAccrued(id, c0), 0, "accrual not zeroed");
    }

    function test_harvest_onlyPoolManagerCallback() public {
        vm.expectRevert(FairOpenHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
    }
}
