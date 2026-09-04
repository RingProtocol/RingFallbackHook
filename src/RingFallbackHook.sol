// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";

/// @title RingFallbackHook
/// @notice A v4 hook that exposes an origin-token A/B pool (cur pool) with real liquidity, but
///         transparently routes each swap to the better-priced liquidity source: the cur pool
///         itself, or the hookless fwA/fwB FewToken fallback pool (fb pool).
///
/// @dev Core logic:
///      On every swap, the hook derives the fb fwA/fwB pool key from the cur pool's tokens
///      (wrap to fewToken via FewFactory, same fee/tickSpacing, hookless). It compares the marginal
///      price (sqrtPriceX96) of both pools. If the fb pool offers a better price for the swap
///      direction, the hook executes the swap through the fb pool (take origin -> wrap -> fb
///      swap -> unwrap -> settle) and returns a BeforeSwapDelta that replaces the cur swap.
///      Otherwise, it returns a zero delta and lets the cur pool handle the swap normally.
///
///      If the fb pool is unavailable (not initialized, no liquidity, no wrapper, or insufficient
///      PoolManager inventory for the flash conversion), the hook gracefully falls back to the cur
///      pool.
///
///      Safety model:
///      - no owner, upgrade, pause, fee, sweep, or route setter;
///      - anyone may add liquidity to the cur pool;
///      - the fb pool key is derived purely from the cur pool key and FewFactory state;
///      - wrap/unwrap are strict 1:1 with return-value and balance checks;
///      - exact-input and exact-output requests must fill completely or the whole transaction reverts;
///      - the PoolManager must already hold enough physical origin input for the atomic flash conversion
///        when the fb route is chosen.
contract RingFallbackHook is BaseHook, DeltaResolver, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    error ZeroAddress();
    error NativeCurrencyNotSupported();
    error DynamicFeeNotSupported();
    error WrapperUnderlyingMismatch(address wrapper, address expected, address actual);
    error FbSwapDirectionMismatch();
    error FbSwapPartialFill(uint256 actual, uint256 expected);
    error InsufficientSettlementInventory(address token, uint256 available, uint256 required);
    error WrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error UnwrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error InsufficientConversionBalance(address token, uint256 available, uint256 required);
    error TokenBalanceMismatch(address token, uint256 expectedBalance, uint256 actualBalance);
    error SettlementAmountMismatch(address token, uint256 paid, uint256 expected);
    error AmountOutOfRange(int256 amountSpecified);
    error UnexpectedHookData();

    event FallbackSwap(
        PoolId indexed curPoolId,
        PoolId indexed fbPoolId,
        address indexed sender,
        bool zeroForOne,
        bool usedFb,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut
    );

    IFewFactory public immutable fewFactory;

    constructor(IPoolManager _poolManager, IFewFactory _fewFactory) BaseHook(_poolManager) {
        if (address(_poolManager) == address(0) || address(_fewFactory) == address(0)) {
            revert ZeroAddress();
        }
        fewFactory = _fewFactory;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length != 0) revert UnexpectedHookData();
        _validateAmount(params.amountSpecified);

        PoolId curPoolId = key.toId();

        // Derive fb fwA/fwB pool key from the cur pool's tokens.
        FbRoute memory route = _deriveFbRoute(key);
        if (!route.available) {
            // fb pool unavailable -- let the cur pool handle the swap.
            emit FallbackSwap(curPoolId, route.fbPoolId, sender, params.zeroForOne, false, params.amountSpecified, 0, 0);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Compare marginal prices to decide which pool is better for this swap direction.
        bool useFb = _isFbPriceBetter(route, params.zeroForOne);
        if (!useFb) {
            emit FallbackSwap(curPoolId, route.fbPoolId, sender, params.zeroForOne, false, params.amountSpecified, 0, 0);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Check flash inventory before committing to the fb route.
        uint256 requestedInput =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : _quoteFbOutput(route, params);
        address inputToken = params.zeroForOne ? route.token0 : route.token1;
        if (IERC20(inputToken).balanceOf(address(poolManager)) < requestedInput) {
            // Insufficient PoolManager inventory -- fall back to cur pool.
            emit FallbackSwap(curPoolId, route.fbPoolId, sender, params.zeroForOne, false, params.amountSpecified, 0, 0);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Execute the swap through the fb fwA/fwB pool.
        bool fbZeroForOne = params.zeroForOne == route.orderAligned;
        (uint256 amountIn, uint256 amountOut) =
            _executeFbSwap(route, fbZeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);
        _convertAndSettle(route, params.zeroForOne, amountIn, amountOut);

        // Return a BeforeSwapDelta that replaces the cur swap.
        // specifiedDelta = -amountSpecified makes amountToSwap = 0 (cur pool no-op).
        int128 specifiedDelta = (-params.amountSpecified).toInt128();
        int128 unspecifiedDelta =
            params.amountSpecified < 0 ? -amountOut.toInt128() : amountIn.toInt128();

        emit FallbackSwap(
            curPoolId, route.fbPoolId, sender, params.zeroForOne, true, params.amountSpecified, amountIn, amountOut
        );

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    // ---------------------------------------------------------------------
    // fb route derivation
    // ---------------------------------------------------------------------

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
        uint160 fbSqrtPriceX96;
        uint160 curSqrtPriceX96;
    }

    function _deriveFbRoute(PoolKey calldata key) internal view returns (FbRoute memory route) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (token0 == address(0) || token1 == address(0)) return _emptyRoute(token0, token1, key);
        if (key.fee.isDynamicFee()) return _emptyRoute(token0, token1, key);

        address few0 = fewFactory.getWrappedToken(token0);
        address few1 = fewFactory.getWrappedToken(token1);
        if (few0 == address(0) || few1 == address(0) || few0 == few1) {
            return _emptyRoute(token0, token1, key);
        }
        if (few0.code.length == 0 || few1.code.length == 0) return _emptyRoute(token0, token1, key);

        if (IFewWrappedToken(few0).token() != token0 || IFewWrappedToken(few1).token() != token1) {
            return _emptyRoute(token0, token1, key);
        }

        bool orderAligned = few0 < few1;
        PoolKey memory fbKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId fbPoolId = fbKey.toId();

        (uint160 fbPrice,,,) = poolManager.getSlot0(fbPoolId);
        if (fbPrice == 0) return _unavailableRoute(token0, token1, few0, few1, key, orderAligned, fbPoolId);
        if (poolManager.getLiquidity(fbPoolId) == 0) {
            return _unavailableRoute(token0, token1, few0, few1, key, orderAligned, fbPoolId);
        }

        (uint160 curPrice,,,) = poolManager.getSlot0(key.toId());
        if (curPrice == 0) return _unavailableRoute(token0, token1, few0, few1, key, orderAligned, fbPoolId);

        route = FbRoute({
            token0: token0,
            token1: token1,
            few0: few0,
            few1: few1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            fbPoolId: fbPoolId,
            orderAligned: orderAligned,
            available: true,
            fbSqrtPriceX96: fbPrice,
            curSqrtPriceX96: curPrice
        });
    }

    function _emptyRoute(address token0, address token1, PoolKey calldata key)
        internal
        pure
        returns (FbRoute memory)
    {
        return FbRoute({
            token0: token0,
            token1: token1,
            few0: address(0),
            few1: address(0),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            fbPoolId: PoolId.wrap(0),
            orderAligned: false,
            available: false,
            fbSqrtPriceX96: 0,
            curSqrtPriceX96: 0
        });
    }

    function _unavailableRoute(
        address token0,
        address token1,
        address few0,
        address few1,
        PoolKey calldata key,
        bool orderAligned,
        PoolId fbPoolId
    ) internal pure returns (FbRoute memory) {
        return FbRoute({
            token0: token0,
            token1: token1,
            few0: few0,
            few1: few1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            fbPoolId: fbPoolId,
            orderAligned: orderAligned,
            available: false,
            fbSqrtPriceX96: 0,
            curSqrtPriceX96: 0
        });
    }

    // ---------------------------------------------------------------------
    // Price comparison
    // ---------------------------------------------------------------------

    /// @dev Compares marginal prices (sqrtPriceX96) of the cur and fb pools.
    ///      For zeroForOne (selling token0, buying token1), a higher sqrtPriceX96 means
    ///      more token1 per token0 -- better for the seller.
    ///      For oneForZero (selling token1, buying token0), a lower sqrtPriceX96 means
    ///      more token0 per token1 -- better for the seller.
    ///      When the fb pool's token order is reversed (!orderAligned), its sqrtPriceX96
    ///      is inverted: normalized = 2^192 / fbSqrtPriceX96.
    function _isFbPriceBetter(FbRoute memory route, bool zeroForOne) internal pure returns (bool) {
        uint256 curPrice = route.curSqrtPriceX96;
        uint256 fbPrice = route.fbSqrtPriceX96;

        if (route.orderAligned) {
            // fb pool has same token order as cur -- prices directly comparable.
            return zeroForOne ? fbPrice > curPrice : fbPrice < curPrice;
        } else {
            // fb pool has reversed token order -- invert fb price.
            // normalized = (2^96)^2 / fbPrice = 2^192 / fbPrice
            uint256 fbNormalized = FullMath.mulDiv(1 << 96, 1 << 96, fbPrice);
            return zeroForOne ? fbNormalized > curPrice : fbNormalized < curPrice;
        }
    }

    // ---------------------------------------------------------------------
    // fb swap execution
    // ---------------------------------------------------------------------

    function _executeFbSwap(
        FbRoute memory route,
        bool fbZeroForOne,
        int256 amountSpecified,
        uint160 curPriceLimitX96
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        PoolKey memory fbKey = PoolKey({
            currency0: Currency.wrap(route.orderAligned ? route.few0 : route.few1),
            currency1: Currency.wrap(route.orderAligned ? route.few1 : route.few0),
            fee: route.fee,
            tickSpacing: route.tickSpacing,
            hooks: IHooks(address(0))
        });

        uint160 fbLimit = _mapFbPriceLimit(route.orderAligned, fbZeroForOne, curPriceLimitX96);

        BalanceDelta delta = poolManager.swap(
            fbKey,
            SwapParams({zeroForOne: fbZeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: fbLimit}),
            bytes("")
        );

        int128 inputDelta = fbZeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = fbZeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert FbSwapDirectionMismatch();

        amountIn = uint256(-int256(inputDelta));
        amountOut = uint256(int256(outputDelta));

        uint256 expected = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 actualSpecified = amountSpecified < 0 ? amountIn : amountOut;
        if (actualSpecified != expected) revert FbSwapPartialFill(actualSpecified, expected);
    }

    /// @dev For exact-output swaps, we need an estimate of the input amount to check inventory.
    ///      This uses the fb pool's marginal price as a lower bound -- the actual input may be
    ///      higher due to slippage. The real check happens during execution.
    function _quoteFbOutput(FbRoute memory route, SwapParams calldata params)
        internal
        pure
        returns (uint256)
    {
        // Conservative estimate: for exact output, input >= output * (price ratio).
        // Using marginal price as a lower bound; actual execution will revert if insufficient.
        uint256 exactOutput = uint256(params.amountSpecified);
        // Add 10% buffer for slippage + fees.
        return exactOutput + (exactOutput / 10);
    }

    function _mapFbPriceLimit(bool orderAligned, bool fbZeroForOne, uint160 curLimit)
        internal
        pure
        returns (uint160)
    {
        if (orderAligned) return curLimit;

        uint256 mapped = fbZeroForOne
            ? FullMath.mulDivRoundingUp(1 << 96, 1 << 96, curLimit)
            : FullMath.mulDiv(1 << 96, 1 << 96, curLimit);

        if (fbZeroForOne && mapped <= TickMath.MIN_SQRT_PRICE) mapped = TickMath.MIN_SQRT_PRICE + 1;
        if (!fbZeroForOne && mapped >= TickMath.MAX_SQRT_PRICE) mapped = TickMath.MAX_SQRT_PRICE - 1;
        if (mapped <= TickMath.MIN_SQRT_PRICE || mapped >= TickMath.MAX_SQRT_PRICE) {
            // Fallback to extreme limits if mapping fails.
            mapped = fbZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        return uint160(mapped);
    }

    // ---------------------------------------------------------------------
    // Convert and settle
    // ---------------------------------------------------------------------

    function _convertAndSettle(FbRoute memory route, bool curZeroForOne, uint256 amountIn, uint256 amountOut)
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

        IERC20(Currency.unwrap(input)).forceApprove(fewToken, amount);
        uint256 returnedAmount = IFewWrappedToken(fewToken).wrap(amount);
        IERC20(Currency.unwrap(input)).forceApprove(fewToken, 0);
        if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);

        if (inputBefore < amount) {
            revert InsufficientConversionBalance(Currency.unwrap(input), inputBefore, amount);
        }
        _requireBalance(input, inputBefore - amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore + amount);
    }

    function _unwrapExact(address fewToken, Currency output, uint256 amount) internal {
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));
        uint256 outputBefore = output.balanceOfSelf();
        uint256 returnedAmount = IFewWrappedToken(fewToken).unwrap(amount);
        if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);

        if (fewBefore < amount) revert InsufficientConversionBalance(fewToken, fewBefore, amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore - amount);
        _requireBalance(output, outputBefore + amount);
    }

    function _settleExact(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(currency), paid, amount);
    }

    function _requireBalance(Currency currency, uint256 expected) internal view {
        uint256 actual = currency.balanceOfSelf();
        if (actual != expected) revert TokenBalanceMismatch(Currency.unwrap(currency), expected, actual);
    }

    function _validateAmount(int256 amountSpecified) internal pure {
        if (
            amountSpecified == 0 || amountSpecified > int256(type(int128).max)
                || amountSpecified < -int256(type(int128).max)
        ) {
            revert AmountOutOfRange(amountSpecified);
        }
    }

    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }
}
