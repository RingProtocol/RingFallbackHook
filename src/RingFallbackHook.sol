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
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";

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
contract RingFallbackHook is BaseHook, DeltaResolver, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    error ZeroAddress();
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
    error FallbackRouteUnavailable();
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
        bool set;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);
        _;
    }

    constructor(IPoolManager _poolManager, IFewFactory _fewFactory, IWETH9 _weth) BaseHook(_poolManager) {
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
    ///         and its currencies must be FewToken wrappers for the cur pool's origin currencies.
    ///         Passing an empty `fbPoolKey` (currency0 == address(0)) removes the registration,
    ///         causing the hook to fall back to FewFactory auto-inference for that cur pool.
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

        fbPools[curPoolId] = FbPool({fbPoolKey: fbPoolKey, set: true});
        emit FbPoolSet(curPoolId, fbPoolKey);
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
        FbRoute memory route = _deriveFbRoute(key);
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
                : _estimateFbAmountIn(route, fbZeroForOne, uint256(params.amountSpecified));
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

        _convertAndSettle(route, params.zeroForOne, amountIn, amountOut);

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

    function _deriveFbRoute(PoolKey calldata key) internal view returns (FbRoute memory route) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Native ETH (address(0)) maps to WETH for wrapper lookup. The fb pool uses FewWETH
        // (whose underlying is WETH), and the hook bridges ETH <-> WETH <-> FewWETH atomically.
        address lookup0 = token0 == address(0) ? address(weth) : token0;
        address lookup1 = token1 == address(0) ? address(weth) : token1;

        if (key.fee.isDynamicFee()) return _emptyRoute(token0, token1, key.fee, key.tickSpacing);

        // 1. Owner-registered fb pool takes precedence over FewFactory auto-inference.
        PoolId curPoolId = key.toId();
        FbPool memory registered = fbPools[curPoolId];
        if (registered.set) {
            PoolKey memory fbKey = registered.fbPoolKey;
            address regFew0 = Currency.unwrap(fbKey.currency0);
            address regFew1 = Currency.unwrap(fbKey.currency1);
            // Validate hookless + wrappers at runtime (wrappers may have been compromised).
            if (address(fbKey.hooks) != address(0)) {
                return _emptyRoute(token0, token1, key.fee, key.tickSpacing);
            }
            // Determine which fb currency wraps which origin token, and validate wrappers.
            (bool orderAligned, address regResolvedFew0, address regResolvedFew1) =
                _resolveFbOrder(regFew0, regFew1, lookup0, lookup1);
            if (regResolvedFew0 == address(0)) {
                return _emptyRoute(token0, token1, key.fee, key.tickSpacing);
            }
            return _assembleRouteFromKey(token0, token1, regResolvedFew0, regResolvedFew1, fbKey, orderAligned);
        }

        // 2. Fall back to FewFactory auto-inference, reusing the cur pool's fee and tick spacing.
        address few0 = fewFactory.getWrappedToken(lookup0);
        address few1 = fewFactory.getWrappedToken(lookup1);
        if (!_validateWrappers(few0, few1, lookup0, lookup1)) {
            return _emptyRoute(token0, token1, key.fee, key.tickSpacing);
        }
        return _assembleRoute(token0, token1, few0, few1, key.fee, key.tickSpacing);
    }

    /// @dev Given two fb pool currencies (fewTokens), determines which wraps `lookup0` and which wraps
    ///      `lookup1`. Returns `(orderAligned, few0, few1)` where `few0` wraps `lookup0` (cur token0)
    ///      and `few1` wraps `lookup1` (cur token1). `orderAligned` is true when the fb pool's
    ///      currency0 wraps cur token0 (same ordering as cur). Returns `(false, address(0), address(0))`
    ///      if validation fails.
    function _resolveFbOrder(address regFew0, address regFew1, address lookup0, address lookup1)
        internal
        view
        returns (bool orderAligned, address few0, address few1)
    {
        if (regFew0 == address(0) || regFew1 == address(0) || regFew0 == regFew1) {
            return (false, address(0), address(0));
        }
        if (regFew0.code.length == 0 || regFew1.code.length == 0) return (false, address(0), address(0));

        address underlying0 = IFewWrappedToken(regFew0).token();
        address underlying1 = IFewWrappedToken(regFew1).token();

        if (underlying0 == lookup0 && underlying1 == lookup1) {
            return (true, regFew0, regFew1);
        } else if (underlying0 == lookup1 && underlying1 == lookup0) {
            return (false, regFew1, regFew0);
        } else {
            return (false, address(0), address(0));
        }
    }

    /// @dev Validates that two FewToken wrappers are distinct, deployed, and wrap the expected underlying
    ///      tokens. For native ETH the expected underlying is WETH (not address(0)).
    function _validateWrappers(address few0, address few1, address lookup0, address lookup1)
        internal
        view
        returns (bool)
    {
        if (few0 == address(0) || few1 == address(0) || few0 == few1) return false;
        if (few0.code.length == 0 || few1.code.length == 0) return false;
        if (IFewWrappedToken(few0).token() != lookup0 || IFewWrappedToken(few1).token() != lookup1) return false;
        return true;
    }

    /// @dev Builds a route from validated wrappers and an explicit fee/tickSpacing (which may differ from
    ///      the cur pool when an owner-registered fb pool is used). Reads fb active liquidity.
    function _assembleRoute(address token0, address token1, address few0, address few1, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (FbRoute memory)
    {
        bool orderAligned = few0 < few1;
        PoolKey memory fbKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId fbPoolId = fbKey.toId();

        uint128 fbLiquidity = poolManager.getLiquidity(fbPoolId);
        if (fbLiquidity == 0) {
            return _buildRoute(token0, token1, few0, few1, fee, tickSpacing, orderAligned, fbPoolId, false);
        }

        return _buildRoute(token0, token1, few0, few1, fee, tickSpacing, orderAligned, fbPoolId, true);
    }

    /// @dev Builds a route from a registered fbPoolKey. `few0` wraps cur token0, `few1` wraps cur token1
    ///      (already resolved by `_resolveFbOrder`). `orderAligned` indicates whether the fb pool's
    ///      currency0 corresponds to cur token0. Reads fb active liquidity.
    function _assembleRouteFromKey(
        address token0,
        address token1,
        address few0,
        address few1,
        PoolKey memory fbKey,
        bool orderAligned
    ) internal view returns (FbRoute memory) {
        PoolId fbPoolId = fbKey.toId();

        uint128 fbLiquidity = poolManager.getLiquidity(fbPoolId);
        if (fbLiquidity == 0) {
            return _buildRoute(token0, token1, few0, few1, fbKey.fee, fbKey.tickSpacing, orderAligned, fbPoolId, false);
        }

        return _buildRoute(token0, token1, few0, few1, fbKey.fee, fbKey.tickSpacing, orderAligned, fbPoolId, true);
    }

    function _buildRoute(
        address token0,
        address token1,
        address few0,
        address few1,
        uint24 fee,
        int24 tickSpacing,
        bool orderAligned,
        PoolId fbPoolId,
        bool available
    ) internal pure returns (FbRoute memory) {
        return FbRoute({
            token0: token0,
            token1: token1,
            few0: few0,
            few1: few1,
            fee: fee,
            tickSpacing: tickSpacing,
            fbPoolId: fbPoolId,
            orderAligned: orderAligned,
            available: available
        });
    }

    function _emptyRoute(address token0, address token1, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (FbRoute memory)
    {
        return _buildRoute(token0, token1, address(0), address(0), fee, tickSpacing, false, PoolId.wrap(0), false);
    }

    // ---------------------------------------------------------------------
    // inventory pre-check
    // ---------------------------------------------------------------------

    /// @dev Pre-checks PoolManager physical inventory before committing to the fb swap. If any leg
    ///      would fail at settlement, returns false so the caller gracefully falls back to cur.
    ///
    ///      For the known leg (exact-input: amountIn, exact-output: amountOut), checks exactly.
    ///      For the unknown leg, uses the fb pool's marginal spot price as a conservative estimate:
    ///      - exact-output: marginal amountIn is a lower bound; if available < lower bound, definitely
    ///        insufficient → fall back. If available >= lower bound, proceed (post-swap check catches
    ///        the rare case where actual amountIn exceeds the estimate).
    ///      - exact-input: the fewOut side is not pre-checked (marginal amountOut is an upper bound,
    ///        so checking against it could cause false cur-fallbacks). The fb pool's LPs deposited
    ///        fewTokens into PoolManager, so fewOut is normally available; if not, the take reverts.
    function _hasFbInventory(FbRoute memory route, bool curZeroForOne, bool fbZeroForOne, int256 amountSpecified)
        internal
        view
        returns (bool)
    {
        address inputToken = curZeroForOne ? route.token0 : route.token1;
        address fewOut = curZeroForOne ? route.few1 : route.few0;

        uint256 availableInput = Currency.wrap(inputToken).balanceOf(address(poolManager));
        uint256 availableFewOut = IERC20(fewOut).balanceOf(address(poolManager));

        if (amountSpecified < 0) {
            // Exact-input: amountIn is known.
            uint256 amountIn = uint256(-amountSpecified);
            if (availableInput < amountIn) return false;
            // fewOut side not pre-checked (see NatSpec above).
            return true;
        } else {
            // Exact-output: amountOut is known.
            uint256 amountOut = uint256(amountSpecified);
            if (availableFewOut < amountOut) return false;
            // Estimate marginal amountIn (lower bound) from fb spot price.
            uint256 estimatedAmountIn = _estimateFbAmountIn(route, fbZeroForOne, amountOut);
            if (estimatedAmountIn == type(uint256).max) return false; // fb pool not initialized
            if (availableInput < estimatedAmountIn) return false;
            return true;
        }
    }

    /// @dev Returns the marginal (minimum) amountIn needed for an exact-output swap of `amountOut`
    ///      on the fb pool, using its current sqrtPriceX96. This is a lower bound — the actual
    ///      amountIn is >= this due to price impact. Uses two-step FullMath to avoid overflow.
    function _estimateFbAmountIn(FbRoute memory route, bool fbZeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(route.fbPoolId);
        if (sqrtPriceX96 == 0) return type(uint256).max;

        // sqrtPriceX96 = sqrt(price) * 2^96, where price = fbCurrency1 / fbCurrency0.
        // fbZeroForOne (selling fbCurrency0, buying fbCurrency1):
        //   amountIn = amountOut / price = amountOut * 2^192 / sqrtPriceX96^2
        // !fbZeroForOne (selling fbCurrency1, buying fbCurrency0):
        //   amountIn = amountOut * price = amountOut * sqrtPriceX96^2 / 2^192
        if (fbZeroForOne) {
            return FullMath.mulDiv(FullMath.mulDiv(amountOut, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        } else {
            return FullMath.mulDiv(FullMath.mulDiv(amountOut, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        }
    }

    // ---------------------------------------------------------------------
    // fb swap execution
    // ---------------------------------------------------------------------

    function _executeFbSwap(FbRoute memory route, bool fbZeroForOne, int256 amountSpecified, uint160 curPriceLimitX96)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
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

    function _mapFbPriceLimit(bool orderAligned, bool fbZeroForOne, uint160 curLimit) internal pure returns (uint160) {
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

    function _convertAndSettle(FbRoute memory route, bool curZeroForOne, uint256 amountIn, uint256 amountOut) internal {
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
            uint256 wethBefore = IERC20(address(weth)).balanceOf(address(this));
            weth.deposit{value: amount}();
            IERC20(address(weth)).forceApprove(fewToken, amount);
            uint256 returnedAmount = IFewWrappedToken(fewToken).wrap(amount);
            IERC20(address(weth)).forceApprove(fewToken, 0);
            if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);
            _requireBalance(Currency.wrap(address(weth)), wethBefore);
        } else {
            IERC20(Currency.unwrap(input)).forceApprove(fewToken, amount);
            uint256 returnedAmount = IFewWrappedToken(fewToken).wrap(amount);
            IERC20(Currency.unwrap(input)).forceApprove(fewToken, 0);
            if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);
        }

        if (inputBefore < amount) {
            revert InsufficientConversionBalance(Currency.unwrap(input), inputBefore, amount);
        }
        _requireBalance(input, inputBefore - amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore + amount);
    }

    function _unwrapExact(address fewToken, Currency output, uint256 amount) internal {
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));
        uint256 outputBefore = output.balanceOfSelf();

        if (output.isAddressZero()) {
            uint256 wethBefore = IERC20(address(weth)).balanceOf(address(this));
            uint256 returnedAmount = IFewWrappedToken(fewToken).unwrap(amount);
            if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
            weth.withdraw(amount);
            _requireBalance(Currency.wrap(address(weth)), wethBefore);
        } else {
            uint256 returnedAmount = IFewWrappedToken(fewToken).unwrap(amount);
            if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
        }

        if (fewBefore < amount) revert InsufficientConversionBalance(fewToken, fewBefore, amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore - amount);
        _requireBalance(output, outputBefore + amount);
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
