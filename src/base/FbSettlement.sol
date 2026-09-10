// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {FbRouteLib} from "../libraries/FbRouteLib.sol";

/// @notice Wrap/unwrap/settle primitives shared by the hook. Extracted to limit main-contract audit scope.
abstract contract FbSettlement is DeltaResolver {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    error WrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error UnwrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error InsufficientConversionBalance(address token, uint256 available, uint256 required);
    error TokenBalanceMismatch(address token, uint256 expectedBalance, uint256 actualBalance);
    error SettlementAmountMismatch(address token, uint256 paid, uint256 expected);

    IWETH9 internal immutable _weth;

    constructor(IWETH9 weth) {
        _weth = weth;
    }

    function convertAndSettle(FbRouteLib.FbRoute memory route, bool curZeroForOne, uint256 amountIn, uint256 amountOut)
        internal
    {
        Currency input = Currency.wrap(curZeroForOne ? route.token0 : route.token1);
        Currency output = Currency.wrap(curZeroForOne ? route.token1 : route.token0);
        address fewIn = curZeroForOne ? route.few0 : route.few1;
        address fewOut = curZeroForOne ? route.few1 : route.few0;

        // Input leg: take origin from PoolManager, wrap to fewToken, settle fewToken for fb swap.
        uint256 inputBaseline = input.balanceOfSelf();
        uint256 fewInBaseline = IERC20(fewIn).balanceOf(address(this));
        _take(input, address(this), amountIn);
        _wrapExact(input, fewIn, amountIn);
        _settleExact(Currency.wrap(fewIn), amountIn);
        _requireBalance(input, inputBaseline);
        _requireBalance(Currency.wrap(fewIn), fewInBaseline);

        // Output leg: take fewToken from PoolManager, unwrap to origin, settle origin for caller.
        uint256 outputBaseline = output.balanceOfSelf();
        uint256 fewOutBaseline = IERC20(fewOut).balanceOf(address(this));
        _take(Currency.wrap(fewOut), address(this), amountOut);
        _unwrapExact(fewOut, output, amountOut);
        _settleExact(output, amountOut);
        _requireBalance(Currency.wrap(fewOut), fewOutBaseline);
        _requireBalance(output, outputBaseline);
    }

    function _wrapExact(Currency input, address fewToken, uint256 amount) internal {
        uint256 inputBefore = input.balanceOfSelf();
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));

        if (input.isAddressZero()) {
            uint256 wethBefore = IERC20(address(_weth)).balanceOf(address(this));
            _weth.deposit{value: amount}();
            _approveAndWrap(address(_weth), fewToken, amount);
            _requireBalance(Currency.wrap(address(_weth)), wethBefore);
        } else {
            _approveAndWrap(Currency.unwrap(input), fewToken, amount);
        }

        if (inputBefore < amount) revert InsufficientConversionBalance(Currency.unwrap(input), inputBefore, amount);
        _requireBalance(input, inputBefore - amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore + amount);
    }

    function _unwrapExact(address fewToken, Currency output, uint256 amount) internal {
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));
        uint256 outputBefore = output.balanceOfSelf();
        uint256 wethBefore = output.isAddressZero() ? IERC20(address(_weth)).balanceOf(address(this)) : 0;

        uint256 returnedAmount = IFewWrappedToken(fewToken).unwrap(amount);
        if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
        if (output.isAddressZero()) {
            _weth.withdraw(amount);
            _requireBalance(Currency.wrap(address(_weth)), wethBefore);
        }

        if (fewBefore < amount) revert InsufficientConversionBalance(fewToken, fewBefore, amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore - amount);
        _requireBalance(output, outputBefore + amount);
    }

    function _approveAndWrap(address underlying, address fewToken, uint256 amount) internal {
        IERC20(underlying).forceApprove(fewToken, amount);
        uint256 returnedAmount = IFewWrappedToken(fewToken).wrap(amount);
        IERC20(underlying).forceApprove(fewToken, 0);
        if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);
    }

    function _settleExact(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        uint256 paid;
        if (currency.isAddressZero()) {
            paid = poolManager.settle{value: amount}();
        } else {
            currency.transfer(address(poolManager), amount);
            paid = poolManager.settle();
        }
        if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(currency), paid, amount);
    }

    function _requireBalance(Currency currency, uint256 expected) internal view {
        uint256 actual = currency.balanceOfSelf();
        if (actual != expected) revert TokenBalanceMismatch(Currency.unwrap(currency), expected, actual);
    }

    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }
}
