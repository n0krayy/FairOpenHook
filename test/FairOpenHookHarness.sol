// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FairOpenHook} from "../src/FairOpenHook.sol";

/// @notice Test harness exposing FairOpenHook's internal fee math.
contract FairOpenHookHarness is FairOpenHook {
    constructor(IPoolManager _poolManager, Params memory _params) FairOpenHook(_poolManager, _params) {}

    function exposedFeeForImpact(uint256 impactBps) external view returns (uint24) {
        return _feeForImpact(impactBps);
    }

    function exposedEstimateImpactBps(PoolKey calldata key, SwapParams calldata p)
        external
        view
        returns (uint256)
    {
        return _estimateImpactBps(key, p);
    }

    function exposedPriceMoveBps(uint160 sqrtP1, uint160 sqrtP0) external pure returns (uint256) {
        return _priceMoveBps(sqrtP1, sqrtP0);
    }
}
