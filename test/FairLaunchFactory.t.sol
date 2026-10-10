// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";
import {FairLaunchFactory, FairLaunchToken} from "../src/FairLaunchFactory.sol";

contract FairLaunchFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FairLaunchFactory factory;
    MockERC20 fakeIMD;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    PoolSwapTest.TestSettings internal _settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        factory = new FairLaunchFactory(IPoolManager(address(manager)));
        fakeIMD = new MockERC20("IMD", "IMD", 18);
        fakeIMD.mint(address(this), 1_000_000 ether);
    }

    function _defaultParams() internal pure returns (FairOpenHook.Params memory) {
        return FairOpenHook.Params({
            windowBlocks: 100,
            baseFee: 3_000,
            maxFee: 900_000,
            feeK: 150,
            breakerBps: 2_500,
            maxBuyPerWallet: 4_500_000 ether,
            cooldownBlocks: 3,
            treasury: address(0)
        });
    }

    function _mineSalt(FairOpenHook.Params memory hp) internal returns (address, bytes32) {
        return HookMiner.find(
            address(factory), FLAGS, type(FairOpenHook).creationCode, abi.encode(address(manager), hp)
        );
    }

    function _launchParams(bytes32 salt, FairOpenHook.Params memory hp)
        internal
        view
        returns (FairLaunchFactory.LaunchParams memory)
    {
        return FairLaunchFactory.LaunchParams({
            name: "TestCoin",
            symbol: "TEST",
            pairCurrency: Currency.wrap(address(fakeIMD)),
            hookParams: hp,
            hookSalt: salt,
            sqrtPriceX96: SQRT_PRICE_1_1,
            seedAmount: 900_000_000 ether,
            rangeGap: 120,
            rangeWidth: 6000
        });
    }

    // ------------------------------------------------------------------
    // launch() end-to-end
    // ------------------------------------------------------------------

    function test_launch_endToEnd() public {
        FairOpenHook.Params memory hp = _defaultParams();
        (address hookAddr, bytes32 salt) = _mineSalt(hp);

        // predict the token address (factory's next CREATE)
        address tokenAddr = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        // predict poolId: sort token vs fakeIMD
        (Currency c0, Currency c1) = tokenAddr < address(fakeIMD)
            ? (Currency.wrap(tokenAddr), Currency.wrap(address(fakeIMD)))
            : (Currency.wrap(address(fakeIMD)), Currency.wrap(tokenAddr));
        PoolKey memory expectedKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        vm.expectEmit(true, true, true, true);
        emit FairLaunchFactory.LaunchCreated(
            tokenAddr, expectedKey.toId(), hookAddr, address(this)
        );

        (FairLaunchToken token, PoolKey memory key, FairOpenHook hook) =
            factory.launch(_launchParams(salt, hp));

        // token deployed, 1B supply
        assertEq(address(token), tokenAddr, "token address mismatch");
        assertEq(token.totalSupply(), 1_000_000_000 ether, "supply mismatch");

        // hook deployed at the mined address with the right flags
        assertEq(address(hook), hookAddr, "hook address mismatch");
        IHooks h = IHooks(address(hook));
        assertTrue(Hooks.hasPermission(h, Hooks.BEFORE_INITIALIZE_FLAG));
        assertTrue(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(h, Hooks.AFTER_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));

        // pool initialized with the hook; window bookkeeping ran
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(expectedKey.toId()), "pool key mismatch");
        assertEq(hook.openBlock(key.toId()), block.number, "openBlock not recorded");
        // NOTE: the seed position is single-sided and out-of-range (like real
        // Community Coins launches), so *active* liquidity is 0 — the token
        // balance below is the proof of seeding.

        // ~900M seeded into the pool, ~100M remainder to the launcher (this test)
        assertApproxEqAbs(
            token.balanceOf(address(manager)), 900_000_000 ether, 1 ether, "seed amount off"
        );
        assertApproxEqAbs(
            token.balanceOf(address(this)), 100_000_000 ether, 1 ether, "remainder off"
        );
    }

    function _create2Addr(bytes32 salt, bytes memory initCode) internal view returns (address) {
        bytes32 h =
            keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode)));
        return address(uint160(uint256(h)));
    }

    function test_launch_revertsOnBadSalt() public {
        FairOpenHook.Params memory hp = _defaultParams();
        bytes memory initCode =
            abi.encodePacked(type(FairOpenHook).creationCode, abi.encode(address(manager), hp));

        // deterministically find a salt whose address LACKS the hook flags
        bytes32 badSalt;
        address badAddr;
        for (uint256 i = 0; i < 1000; i++) {
            badSalt = bytes32(i);
            badAddr = _create2Addr(badSalt, initCode);
            if (uint160(badAddr) & FLAGS != FLAGS) break;
        }
        require(uint160(badAddr) & FLAGS != FLAGS, "no bad salt found in range");

        // the hook constructor itself validates address flags (BaseHook ->
        // Hooks.validateHookPermissions), so a bad salt reverts at deployment
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, badAddr));
        factory.launch(_launchParams(badSalt, hp));
    }

    // ------------------------------------------------------------------
    // swap on a factory pool: dynamic fee is charged, surcharge accrues
    // ------------------------------------------------------------------

    function test_launch_swapChargesFee() public {
        FairOpenHook.Params memory hp = _defaultParams();
        (, bytes32 salt) = _mineSalt(hp);
        (FairLaunchToken token, PoolKey memory key, FairOpenHook hook) =
            factory.launch(_launchParams(salt, hp));
        PoolId id = key.toId();

        // the test (launcher) holds the 100M remainder: add a small two-sided
        // "dust" position in-range so the pool is tradeable (mirrors real launches)
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        fakeIMD.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );

        // small buy of the new token with fakeIMD
        Currency input = Currency.wrap(address(fakeIMD));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(fakeIMD);
        token.approve(address(swapRouter), type(uint256).max);
        fakeIMD.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings,
            ZERO_BYTES
        );

        // dynamic fee charged: surcharge accrued to the hook as ERC6909 claims
        uint256 accrued = hook.surchargeAccrued(id, input);
        assertGt(accrued, 0, "no surcharge accrued");
        assertEq(
            manager.balanceOf(address(hook), input.toId()),
            accrued,
            "hook claim balance mismatch"
        );
    }
}
