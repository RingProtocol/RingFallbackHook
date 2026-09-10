// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";

/// @notice Route + helpers for fb pool derivation. Kept out of the main contract to limit audit scope.
library FbRouteLib {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct FbRoute {
        address token0;
        address token1;
        address few0;
        address few1;
        uint24 fee;
        int24 tickSpacing;
        PoolId fbPoolId;
        bool orderAligned;
        bool available;
    }

    /// @dev Validates that two FewToken wrappers are distinct, deployed, and wrap the expected
    ///      underlying tokens. For native ETH the expected underlying is WETH (not address(0)).
    function validateWrappers(address few0, address few1, address lookup0, address lookup1)
        internal
        view
        returns (bool)
    {
        if (few0 == address(0) || few1 == address(0) || few0 == few1) return false;
        if (few0.code.length == 0 || few1.code.length == 0) return false;
        if (IFewWrappedToken(few0).token() != lookup0 || IFewWrappedToken(few1).token() != lookup1) return false;
        return true;
    }

    /// @dev Builds a route from validated wrappers. Checks fb liquidity to set `available`.
    function buildRoute(
        IPoolManager pm,
        address token0,
        address token1,
        address few0,
        address few1,
        uint24 fee,
        int24 tickSpacing,
        bool orderAligned
    ) internal view returns (FbRoute memory) {
        PoolId fbPoolId = fbKey(few0, few1, fee, tickSpacing, orderAligned).toId();
        return FbRoute({
            token0: token0,
            token1: token1,
            few0: few0,
            few1: few1,
            fee: fee,
            tickSpacing: tickSpacing,
            fbPoolId: fbPoolId,
            orderAligned: orderAligned,
            available: pm.getLiquidity(fbPoolId) > 0
        });
    }

    /// @dev Constructs the fb PoolKey from route components.
    function fbKeyFromRoute(FbRoute memory route) internal pure returns (PoolKey memory) {
        return fbKey(route.few0, route.few1, route.fee, route.tickSpacing, route.orderAligned);
    }

    function fbKey(address few0, address few1, uint24 fee, int24 tickSpacing, bool orderAligned)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }
}
