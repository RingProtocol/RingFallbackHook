// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";
import {FbRouteLib} from "./libraries/FbRouteLib.sol";
import {FbPriceLib} from "./libraries/FbPriceLib.sol";
import {FbSettlement} from "./base/FbSettlement.sol";

/// @title RingFallbackHook
/// @notice A v4 hook that routes all swaps through the hookless fwA/fwB FewToken fallback pool (fb pool).
///
/// @dev Core logic:
///      The hook always routes to fb when available. The cur pool is never used as an execution venue.
///      If fb is unavailable (no route, no liquidity, or insufficient inventory), the swap reverts.
///
///      Slippage protection relies on v4 native mechanisms:
///      - sqrtPriceLimitX96 is mapped to the fb pool's price space before the fb swap.
///      - The caller's router enforces deadline, amountOutMinimum, and amountInMaximum.
///      - fb swaps must fill completely or the whole transaction reverts.
///      hookData is ignored.
///
///      Safety model:
///      - a single transferable `owner` (set to the deployer at construction) can register explicit
///        fb pool mappings; there is no upgrade, fee, pause, or sweep capability;
///      - anyone may add liquidity to the cur pool;
///      - routing always goes to fb; the cur pool is never used as a fallback venue;
///      - the fb pool key is taken from the owner-registered `fbPools` mapping (keyed by cur pool PoolId)
///        when present, otherwise derived purely from the cur pool key and FewFactory state;
///      - wrap/unwrap are strict 1:1 with return-value and balance checks;
///      - exact-input and exact-output requests must fill completely or the whole transaction reverts;
///      - the PoolManager must already hold enough physical origin input for the atomic flash conversion
///        when the fb route is chosen.
contract RingFallbackHook is BaseHook, FbSettlement, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using FbRouteLib for FbRouteLib.FbRoute;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error ZeroAddress();
    error WrapperUnderlyingMismatch(address wrapper, address expected, address actual);
    error FbSwapDirectionMismatch();
    error FbSwapPartialFill(uint256 actual, uint256 expected);
    error InsufficientSettlementInventory(address token, uint256 available, uint256 required);
    error AmountOutOfRange(int256 amountSpecified);
    error NotOwner(address caller, address owner);
    error FbRouteUnavailable();
    error FbInsufficientInventory(address token, uint256 available, uint256 required);
    error FbPoolNotHookless(address hooks);

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
    event OwnerChanged(address indexed previousOwner, address indexed newOwner);
    event FbPoolSet(PoolId indexed curPoolId, PoolKey fbPoolKey);
    event FbPoolRemoved(PoolId indexed curPoolId);

    IFewFactory public immutable fewFactory;
    IWETH9 public immutable weth;

    /// @notice Current owner. Set to the deployer at construction and transferable via `transferOwner`.
    address public owner;

    /// @notice Owner-registered explicit fb pool definitions, keyed by the cur pool's PoolId.
    mapping(PoolId => FbPool) public fbPools;

    struct FbPool {
        PoolKey fbPoolKey;
        bool orderAligned;
        bool set;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);
        _;
    }

    constructor(IPoolManager _poolManager, IFewFactory _fewFactory, IWETH9 _weth)
        BaseHook(_poolManager)
        FbSettlement(_weth)
    {
        if (address(_poolManager) == address(0) || address(_fewFactory) == address(0) || address(_weth) == address(0)) {
            revert ZeroAddress();
        }
        fewFactory = _fewFactory;
        weth = _weth;
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);
    }

    // ---------------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------------

    /// @notice Transfers ownership to `newOwner`. The new owner must not be the zero address.
    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Registers an explicit fb pool for the given cur pool. The `fbPoolKey` must be hookless
    ///         and its currency0/currency1 must be FewToken wrappers for curPoolKey.currency0/currency1
    ///         respectively (same ordering). Passing an empty `fbPoolKey` (currency0 == address(0))
    ///         removes the registration, causing the hook to fall back to FewFactory auto-inference.
    function setFbPool(PoolKey calldata curPoolKey, PoolKey calldata fbPoolKey) external onlyOwner {
        PoolId curPoolId = curPoolKey.toId();

        // Empty fbPoolKey (currency0 == address(0)) means removal.
        if (Currency.unwrap(fbPoolKey.currency0) == address(0)) {
            if (!fbPools[curPoolId].set) return;
            delete fbPools[curPoolId];
            emit FbPoolRemoved(curPoolId);
            return;
        }

        // Validate: hookless, non-zero distinct currencies, v4 ordering.
        if (address(fbPoolKey.hooks) != address(0)) revert FbPoolNotHookless(address(fbPoolKey.hooks));
        if (Currency.unwrap(fbPoolKey.currency1) == address(0)) revert ZeroAddress();
        if (fbPoolKey.currency0 >= fbPoolKey.currency1) revert ZeroAddress();

        // Validate: fbPoolKey.currency0/currency1 must be FewToken wrappers for curPoolKey's
        // currencies (in either order). Native ETH (address(0)) maps to WETH for comparison.
        address curLookup0 = Currency.unwrap(curPoolKey.currency0);
        address curLookup1 = Currency.unwrap(curPoolKey.currency1);
        curLookup0 = curLookup0 == address(0) ? address(weth) : curLookup0;
        curLookup1 = curLookup1 == address(0) ? address(weth) : curLookup1;
        address few0 = Currency.unwrap(fbPoolKey.currency0);
        address few1 = Currency.unwrap(fbPoolKey.currency1);
        if (few0.code.length == 0 || few1.code.length == 0) revert ZeroAddress();

        address underlying0 = IFewWrappedToken(few0).token();
        address underlying1 = IFewWrappedToken(few1).token();
        bool orderAligned;
        if (underlying0 == curLookup0 && underlying1 == curLookup1) {
            orderAligned = true;
        } else if (underlying0 == curLookup1 && underlying1 == curLookup0) {
            orderAligned = false;
        } else {
            revert WrapperUnderlyingMismatch(few0, curLookup0, underlying0);
        }

        fbPools[curPoolId] = FbPool({fbPoolKey: fbPoolKey, orderAligned: orderAligned, set: true});
        emit FbPoolSet(curPoolId, fbPoolKey);
    }

    // ---------------------------------------------------------------------
    // Quote
    // ---------------------------------------------------------------------

    /// @notice Quotes the expected amountIn/amountOut for a swap through the hook's fb route.
    ///         Uses an external V4Quoter to simulate the fb pool swap. Since wrap/unwrap is 1:1,
    ///         the fb pool quote equals the effective quote the user would receive.
    /// @dev Not marked `view` because V4Quoter uses revert-based simulation. Does not modify state.
    function quote(PoolKey calldata curPoolKey, bool zeroForOne, int256 amountSpecified, IV4Quoter v4Quoter)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        FbRouteLib.FbRoute memory route = _deriveFbRoute(curPoolKey);
        if (!route.available) revert FbRouteUnavailable();

        bool fbZeroForOne = zeroForOne == route.orderAligned;
        PoolKey memory fbKey = route.fbKeyFromRoute();

        if (amountSpecified < 0) {
            uint256 exactAmount = uint256(-amountSpecified);
            (amountOut,) = v4Quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: fbKey, zeroForOne: fbZeroForOne, exactAmount: uint128(exactAmount), hookData: bytes("")
                })
            );
            amountIn = exactAmount;
        } else {
            uint256 exactAmount = uint256(amountSpecified);
            (amountIn,) = v4Quoter.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: fbKey, zeroForOne: fbZeroForOne, exactAmount: uint128(exactAmount), hookData: bytes("")
                })
            );
            amountOut = exactAmount;
        }
    }

    /// @dev Required to receive native ETH from PoolManager.take() and WETH9.withdraw().
    receive() external payable {}

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

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    )
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateAmount(params.amountSpecified);

        PoolId curPoolId = key.toId();

        // fb is the only execution venue. If no route is available, revert.
        FbRouteLib.FbRoute memory route = _deriveFbRoute(key);
        if (!route.available) revert FbRouteUnavailable();

        // Pre-check PoolManager physical inventory before committing to the fb swap. If insufficient,
        // revert early to save gas. Slippage protection is provided by sqrtPriceLimitX96 (mapped to
        // fb's price space) and the caller's router deadline/amount limits. hookData is ignored.
        bool fbZeroForOne = params.zeroForOne == route.orderAligned;
        address inputToken = params.zeroForOne ? route.token0 : route.token1;
        uint256 availableInput = Currency.wrap(inputToken).balanceOf(address(poolManager));
        if (!_hasFbInventory(route, params.zeroForOne, fbZeroForOne, params.amountSpecified)) {
            uint256 required = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : FbPriceLib.estimateFbAmountIn(
                    poolManager, route.fbPoolId, fbZeroForOne, uint256(params.amountSpecified)
                );
            revert FbInsufficientInventory(inputToken, availableInput, required);
        }

        (uint256 amountIn, uint256 amountOut) =
            _executeFbSwap(route, fbZeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);

        // Safety net: for exact-output, the pre-check uses a marginal (lower-bound) estimate of
        // amountIn. If actual amountIn exceeds the estimate and PoolManager lacks sufficient origin
        // input, revert. This is a rare edge case — the pre-check catches the common insufficiency.
        if (availableInput < amountIn) {
            revert InsufficientSettlementInventory(inputToken, availableInput, amountIn);
        }

        convertAndSettle(route, params.zeroForOne, amountIn, amountOut);

        int128 specifiedDelta = (-params.amountSpecified).toInt128();
        int128 unspecifiedDelta = params.amountSpecified < 0 ? -amountOut.toInt128() : amountIn.toInt128();

        emit FallbackSwap(
            curPoolId, route.fbPoolId, sender, params.zeroForOne, true, params.amountSpecified, amountIn, amountOut
        );

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    // ---------------------------------------------------------------------
    // fb route derivation
    // ---------------------------------------------------------------------

    function _deriveFbRoute(PoolKey calldata key) internal view returns (FbRouteLib.FbRoute memory route) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Native ETH (address(0)) maps to WETH for wrapper lookup. The fb pool uses FewWETH
        // (whose underlying is WETH), and the hook bridges ETH <-> WETH <-> FewWETH atomically.
        address lookup0 = token0 == address(0) ? address(weth) : token0;
        address lookup1 = token1 == address(0) ? address(weth) : token1;

        if (key.fee.isDynamicFee()) {
            return
                FbRouteLib.buildRoute(
                    poolManager, token0, token1, address(0), address(0), key.fee, key.tickSpacing, false
                );
        }

        // 1. Owner-registered fb pool takes precedence over FewFactory auto-inference.
        FbPool memory registered = fbPools[key.toId()];
        if (registered.set) {
            PoolKey memory fbKey = registered.fbPoolKey;
            bool orderAligned = registered.orderAligned;
            // few0/few1 in the route always wrap cur token0/token1 respectively.
            address regFew0 = Currency.unwrap(orderAligned ? fbKey.currency0 : fbKey.currency1);
            address regFew1 = Currency.unwrap(orderAligned ? fbKey.currency1 : fbKey.currency0);
            // Runtime validation: wrappers may have been compromised after registration.
            if (address(fbKey.hooks) != address(0) || !FbRouteLib.validateWrappers(regFew0, regFew1, lookup0, lookup1))
            {
                return FbRouteLib.buildRoute(
                    poolManager, token0, token1, address(0), address(0), key.fee, key.tickSpacing, false
                );
            }
            return FbRouteLib.buildRoute(
                poolManager, token0, token1, regFew0, regFew1, fbKey.fee, fbKey.tickSpacing, orderAligned
            );
        }

        // 2. Fall back to FewFactory auto-inference, reusing the cur pool's fee and tick spacing.
        address few0 = fewFactory.getWrappedToken(lookup0);
        address few1 = fewFactory.getWrappedToken(lookup1);
        if (!FbRouteLib.validateWrappers(few0, few1, lookup0, lookup1)) {
            return
                FbRouteLib.buildRoute(
                    poolManager, token0, token1, address(0), address(0), key.fee, key.tickSpacing, false
                );
        }
        return FbRouteLib.buildRoute(poolManager, token0, token1, few0, few1, key.fee, key.tickSpacing, few0 < few1);
    }

    // ---------------------------------------------------------------------
    // inventory pre-check
    // ---------------------------------------------------------------------

    /// @dev Pre-checks PoolManager physical inventory before committing to the fb swap.
    function _hasFbInventory(
        FbRouteLib.FbRoute memory route,
        bool curZeroForOne,
        bool fbZeroForOne,
        int256 amountSpecified
    ) internal view returns (bool) {
        address inputToken = curZeroForOne ? route.token0 : route.token1;
        address fewOut = curZeroForOne ? route.few1 : route.few0;

        uint256 availableInput = Currency.wrap(inputToken).balanceOf(address(poolManager));
        uint256 availableFewOut = IERC20(fewOut).balanceOf(address(poolManager));

        if (amountSpecified < 0) {
            // Exact-input: amountIn is known; fewOut side not pre-checked (LPs deposited fewTokens).
            return availableInput >= uint256(-amountSpecified);
        } else {
            // Exact-output: amountOut is known; estimate marginal amountIn (lower bound).
            uint256 amountOut = uint256(amountSpecified);
            if (availableFewOut < amountOut) return false;
            uint256 estimatedAmountIn =
                FbPriceLib.estimateFbAmountIn(poolManager, route.fbPoolId, fbZeroForOne, amountOut);
            if (estimatedAmountIn == type(uint256).max) return false; // fb pool not initialized
            return availableInput >= estimatedAmountIn;
        }
    }

    // ---------------------------------------------------------------------
    // fb swap execution
    // ---------------------------------------------------------------------

    function _executeFbSwap(
        FbRouteLib.FbRoute memory route,
        bool fbZeroForOne,
        int256 amountSpecified,
        uint160 curPriceLimitX96
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        uint160 fbLimit = FbPriceLib.mapFbPriceLimit(route.orderAligned, fbZeroForOne, curPriceLimitX96);

        BalanceDelta delta = poolManager.swap(
            route.fbKeyFromRoute(),
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

    function _validateAmount(int256 amountSpecified) internal pure {
        if (
            amountSpecified == 0 || amountSpecified > int256(type(int128).max)
                || amountSpecified < -int256(type(int128).max)
        ) {
            revert AmountOutOfRange(amountSpecified);
        }
    }
}
