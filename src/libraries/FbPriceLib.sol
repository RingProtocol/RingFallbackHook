// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FbRouteLib} from "./FbRouteLib.sol";

/// @notice Price-limit mapping and marginal amount estimation for fb pools.
library FbPriceLib {
    using StateLibrary for IPoolManager;

    /// @dev Maps a cur-pool sqrtPriceLimitX96 into the fb pool's price space. When the fb pool's
    ///      currency order is reversed relative to cur (`!orderAligned`), the price limit is inverted.
    function mapFbPriceLimit(bool orderAligned, bool fbZeroForOne, uint160 curLimit) internal pure returns (uint160) {
        if (orderAligned) return curLimit;

        uint256 mapped = fbZeroForOne
            ? FullMath.mulDivRoundingUp(1 << 96, 1 << 96, curLimit)
            : FullMath.mulDiv(1 << 96, 1 << 96, curLimit);

        if (fbZeroForOne && mapped <= TickMath.MIN_SQRT_PRICE) mapped = TickMath.MIN_SQRT_PRICE + 1;
        if (!fbZeroForOne && mapped >= TickMath.MAX_SQRT_PRICE) mapped = TickMath.MAX_SQRT_PRICE - 1;
        if (mapped <= TickMath.MIN_SQRT_PRICE || mapped >= TickMath.MAX_SQRT_PRICE) {
            mapped = fbZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        return uint160(mapped);
    }

    /// @dev Returns the marginal (minimum) amountIn needed for an exact-output swap of `amountOut`
    ///      on the fb pool, using its current sqrtPriceX96. Lower bound — actual amountIn is >= this.
    function estimateFbAmountIn(IPoolManager pm, PoolId fbPoolId, bool fbZeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(fbPoolId);
        if (sqrtPriceX96 == 0) return type(uint256).max;

        if (fbZeroForOne) {
            return FullMath.mulDiv(FullMath.mulDiv(amountOut, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        } else {
            return FullMath.mulDiv(FullMath.mulDiv(amountOut, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        }
    }
}
