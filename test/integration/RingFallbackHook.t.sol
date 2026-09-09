// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {RingFallbackHook} from "../../src/RingFallbackHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {MockFewFactory} from "../mocks/MockFewFactory.sol";
import {MockWETH9} from "../mocks/MockWETH9.sol";

/// @notice Integration tests for RingFallbackHook using a fresh local PoolManager and mock FewFactory.
contract RingFallbackHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant SQRT_PRICE_1_2 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_2_1 = 112045541949572279837463876454;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant SWAP_AMOUNT = 1e18;
    uint256 internal constant FB_LIQUIDITY = 100e18;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    MockFewFactory internal factory;
    MockWETH9 internal weth;
    RingFallbackHook internal hook;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Currency internal currencyA;
    Currency internal currencyB;
    Currency internal currency0;
    Currency internal currency1;

    address internal fewA;
    address internal fewB;

    PoolKey internal curKey;
    PoolKey internal fbKey;
    bool internal orderAligned;

    address internal LP = makeAddr("LP");
    address internal USER = makeAddr("USER");

    function setUp() public {
        // Deploy fresh PoolManager and test routers.
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy mock tokens.
        tokenA = new MockERC20("TokenA", "TA", 18);
        tokenB = new MockERC20("TokenB", "TB", 18);
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenA.mint(USER, 100e18);
        tokenB.mint(USER, 100e18);

        currencyA = Currency.wrap(address(tokenA));
        currencyB = Currency.wrap(address(tokenB));
        (currency0, currency1) = address(tokenA) < address(tokenB) ? (currencyA, currencyB) : (currencyB, currencyA);

        // Deploy mock FewFactory and create wrappers.
        factory = new MockFewFactory();
        factory.createToken(address(tokenA));
        factory.createToken(address(tokenB));
        fewA = factory.getWrappedToken(address(tokenA));
        fewB = factory.getWrappedToken(address(tokenB));

        // Deploy mock WETH9 for native ETH support tests.
        weth = new MockWETH9();

        // Mint underlying to PoolManager so the hook can flash-take during fb route.
        // Also mint fewTokens to PoolManager for the fb swap output leg.
        tokenA.mint(address(manager), 1_000_000e18);
        tokenB.mint(address(manager), 1_000_000e18);

        // Deploy the hook at a mined address matching permission flags.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, IFewFactory(address(factory)), IWETH9(address(weth)));
        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(RingFallbackHook).creationCode, constructorArgs);
        hook = new RingFallbackHook{salt: salt}(manager, IFewFactory(address(factory)), IWETH9(address(weth)));
        assertEq(address(hook), minedAddr, "hook address mismatch");

        // Approve tokens for routers.
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(liquidityRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);

        // Approve tokens for the hook (needed for wrap during fb route).
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        // User approvals.
        vm.startPrank(USER);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Construct pool keys.
        curKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Derive fb key the same way the hook does: few0 = getWrappedToken(token0), few1 = getWrappedToken(token1).
        address few0 = factory.getWrappedToken(Currency.unwrap(currency0));
        address few1 = factory.getWrappedToken(Currency.unwrap(currency1));
        orderAligned = few0 < few1;
        fbKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    // ---------------------------------------------------------------------
    // Permission tests
    // ---------------------------------------------------------------------

    function test_permissions_correct() public view {
        Hooks.Permissions memory perm = hook.getHookPermissions();
        assertFalse(perm.beforeInitialize);
        assertFalse(perm.afterInitialize);
        assertFalse(perm.beforeAddLiquidity);
        assertFalse(perm.afterAddLiquidity);
        assertFalse(perm.beforeRemoveLiquidity);
        assertFalse(perm.afterRemoveLiquidity);
        assertTrue(perm.beforeSwap);
        assertFalse(perm.afterSwap);
        assertFalse(perm.beforeDonate);
        assertFalse(perm.afterDonate);
        assertTrue(perm.beforeSwapReturnDelta);
        assertFalse(perm.afterSwapReturnDelta);
        assertFalse(perm.afterAddLiquidityReturnDelta);
        assertFalse(perm.afterRemoveLiquidityReturnDelta);
    }

    function test_constructor_zeroAddress_reverts() public {
        // FewFactory(0) and WETH(0) are blocked by the constructor.
        // We can't test PoolManager(0) directly because BaseHook's validateHookAddress
        // runs first and requires a specific address pattern.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        // FewFactory(0)
        bytes memory constructorArgsA = abi.encode(manager, IFewFactory(address(0)), IWETH9(address(weth)));
        (address minedAddrA, bytes32 saltA) =
            HookMiner.find(address(this), flags, type(RingFallbackHook).creationCode, constructorArgsA);
        vm.expectRevert(RingFallbackHook.ZeroAddress.selector);
        new RingFallbackHook{salt: saltA}(manager, IFewFactory(address(0)), IWETH9(address(weth)));
        minedAddrA;

        // WETH(0)
        bytes memory constructorArgsB = abi.encode(manager, IFewFactory(address(factory)), IWETH9(address(0)));
        (address minedAddrB, bytes32 saltB) =
            HookMiner.find(address(this), flags, type(RingFallbackHook).creationCode, constructorArgsB);
        vm.expectRevert(RingFallbackHook.ZeroAddress.selector);
        new RingFallbackHook{salt: saltB}(manager, IFewFactory(address(factory)), IWETH9(address(0)));
        minedAddrB;
    }

    // ---------------------------------------------------------------------
    // Liquidity tests
    // ---------------------------------------------------------------------

    function test_anyoneCanAddLiquidity() public {
        // Initialize cur pool at 1:1.
        manager.initialize(curKey, SQRT_PRICE_1_1);

        // Give LP some tokens.
        tokenA.mint(LP, 100e18);
        tokenB.mint(LP, 100e18);

        // Anyone (LP) can add liquidity without hook interference.
        vm.startPrank(LP);
        tokenA.approve(address(liquidityRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0});
        liquidityRouter.modifyLiquidity(curKey, params, bytes(""));
        vm.stopPrank();

        assertGt(manager.getLiquidity(curKey.toId()), 0, "liquidity added");
    }

    // ---------------------------------------------------------------------
    // Fallback to cur pool tests
    // ---------------------------------------------------------------------

    function test_emptyHookDataUsesCurWhenFbNotInitialized() public {
        // Initialize cur pool only (fb pool not initialized).
        manager.initialize(curKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);

        // Swap should use cur pool (fb unavailable).
        _swapAsUser(true, -int256(SWAP_AMOUNT));

        // Cur pool should have moved (price changed).
        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(curPriceAfter != SQRT_PRICE_1_1, "cur price moved");
    }

    function test_emptyHookDataUsesCurWhenFbHasNoLiquidity() public {
        // Initialize both pools but only add liquidity to cur.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);

        // fb has no liquidity -> fall back to cur.
        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(curPriceAfter != SQRT_PRICE_1_1, "cur price moved");
    }

    function test_emptyHookDataUsesCurWhenFbLiquidityEqual() public {
        // Both pools at the same price with equal liquidity -> equal depth routes to cur.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);
        _addFbLiquidity(1e18);

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        // Cur pool should have moved (it handled the swap).
        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(curPriceAfter != SQRT_PRICE_1_1, "cur price moved");
    }

    // ---------------------------------------------------------------------
    // fb route tests
    // ---------------------------------------------------------------------

    function test_usesExplicitFb_zeroForOne() public {
        // For zeroForOne (selling token0, buying token1), fb is better when fbPrice > curPrice.
        // When orderAligned, fb sqrtPrice is directly comparable.
        // When !orderAligned, fb sqrtPrice is inverted: normalized = 2^192 / fbSqrtPrice.
        // So we set fb price to SQRT_PRICE_2_1 (higher) when orderAligned,
        // or SQRT_PRICE_1_2 (lower, which inverts to higher) when !orderAligned.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        uint160 fbPrice = _fbPriceForBetterZeroForOne();
        manager.initialize(fbKey, fbPrice);
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
    }

    function test_usesCurWhenFbShallower_evenWithHookData() public {
        // fb price is better for zeroForOne, but fb liquidity is shallower than cur ->
        // depth-based routing selects cur regardless of hookData.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(0.5e18);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT / 1000), _fallbackData(1));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertTrue(curPriceAfter != curPriceBefore, "cur price moved");
        assertEq(fbPriceAfter, fbPriceBefore, "fb price unchanged");
    }

    function test_routesToFbWhenDeeperEvenIfPriceWorse() public {
        // Depth-based routing: fb price is worse for zeroForOne, but fb is strictly deeper ->
        // fb is still used. The fb price sits near the edge of the fb liquidity range in the swap's
        // direction, so use a small amount that still fills completely.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT / 1000));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_usesExplicitFb_oneForZero() public {
        // For oneForZero (selling token1, buying token0), fb is better when fbPrice < curPrice.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        uint160 fbPrice = _fbPriceForBetterOneForZero();
        manager.initialize(fbKey, fbPrice);
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(false, -int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
    }

    function test_fbRoute_hookBalancesZero() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        // Hook should hold no residual balances.
        assertEq(IERC20(address(tokenA)).balanceOf(address(hook)), 0, "hook tokenA balance");
        assertEq(IERC20(address(tokenB)).balanceOf(address(hook)), 0, "hook tokenB balance");
        assertEq(IERC20(fewA).balanceOf(address(hook)), 0, "hook fewA balance");
        assertEq(IERC20(fewB).balanceOf(address(hook)), 0, "hook fewB balance");
    }

    function test_autoRoutesToFbWhenSpotPriceBetter_zeroForOne() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_autoRoutesToFbWhenSpotPriceBetter_oneForZero() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(false, -int256(SWAP_AMOUNT));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_autoRoutesToFbForExactOutput() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, int256(SWAP_AMOUNT));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_autoFbHookBalancesZero() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        assertEq(IERC20(address(tokenA)).balanceOf(address(hook)), 0, "hook tokenA balance");
        assertEq(IERC20(address(tokenB)).balanceOf(address(hook)), 0, "hook tokenB balance");
        assertEq(IERC20(fewA).balanceOf(address(hook)), 0, "hook fewA balance");
        assertEq(IERC20(fewB).balanceOf(address(hook)), 0, "hook fewB balance");
    }

    function test_fbDeeperButTooShallowRevertsOnPartialFill() public {
        // fb is strictly deeper than cur but still too shallow for the requested amount.
        // The fb swap cannot fill completely, so the whole transaction reverts.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, SQRT_PRICE_1_1);
        _addCurLiquidity(0.001e18);
        _addFbLiquidity(0.01e18);

        // v4-core wraps hook reverts in the ERC-7751 error WrappedError(address,bytes4,bytes,bytes)
        // (see Hooks.callHook), so vm.expectRevert(FbSwapPartialFill.selector) cannot match directly.
        // Catch the wrapper, decode it, and assert the inner reason is FbSwapPartialFill.
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        try swapRouter.swap(
            curKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            bytes("")
        ) {
            assertTrue(false, "expected FbSwapPartialFill");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "ERC-7751 wrapper");
            (address target, bytes4 fnSelector, bytes memory inner,) =
                abi.decode(_stripSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(target, address(hook), "wrapper target");
            assertEq(fnSelector, IHooks.beforeSwap.selector, "wrapper selector");
            assertEq(bytes4(inner), RingFallbackHook.FbSwapPartialFill.selector, "FbSwapPartialFill");
            (uint256 actual, uint256 expected) = abi.decode(_stripSelector(inner), (uint256, uint256));
            assertEq(expected, SWAP_AMOUNT, "expected fill");
            assertTrue(actual < expected, "partial fill");
        }
    }

    function test_usesCurWhenFbUnavailable_evenWithHookData() public {
        // fb unavailable → cur is used regardless of hookData.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(curPriceAfter != curPriceBefore, "cur price moved");
    }

    function test_hookDataIgnored_zeroLimitStillRoutesToFb() public {
        // hookData carries no amountLimit semantics; routing is purely depth-based.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(0));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_hookDataIgnored_expiredDeadlineStillRoutesToFb() public {
        // hookData carries no deadline semantics; an expired encoding no longer reverts.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);
        vm.warp(100);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), abi.encode(uint256(99), uint256(1)));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_hookDataIgnored_minOutputNotEnforced() public {
        // hookData carries no minimum-output semantics; a huge limit no longer reverts.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(type(uint256).max));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_usesExplicitFbForExactOutput() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(false, int256(SWAP_AMOUNT), _fallbackData(type(uint256).max));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_usesExplicitFbForExactOutput_zeroForOne() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, int256(SWAP_AMOUNT), _fallbackData(type(uint256).max));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    function test_hookDataIgnored_maxInputNotEnforced() public {
        // hookData carries no maximum-input semantics; a tiny limit no longer reverts.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(false, int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    // ---------------------------------------------------------------------
    // Edge cases
    // ---------------------------------------------------------------------

    function test_revertsOnZeroAmount() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);

        // PoolManager itself reverts on zero amount before the hook is called.
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectRevert();
        swapRouter.swap(
            curKey,
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            bytes("")
        );
    }

    function test_hookDataIgnored_invalidBytesStillSwaps() public {
        // hookData is not validated; arbitrary bytes neither revert nor change routing.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), bytes("invalid"));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());
        assertEq(curPriceAfter, curPriceBefore, "cur price unchanged");
        assertTrue(fbPriceAfter != fbPriceBefore, "fb price moved");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Returns `data` without its leading 4-byte selector, so abi.decode can consume a
    ///      custom-error payload.
    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        bytes memory out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
        return out;
    }

    function _addCurLiquidity(uint256 liquidityAmount) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: int128(int256(liquidityAmount)), salt: 0
        });
        liquidityRouter.modifyLiquidity(curKey, params, bytes(""));
    }

    function _addFbLiquidity(uint256 liquidityAmount) internal {
        // Need to wrap tokens and provide them to the fb pool.
        // The fb pool uses fewTokens, so we need to wrap first and approve the liquidity router.
        uint256 amount0 = liquidityAmount;
        uint256 amount1 = liquidityAmount;

        // Wrap tokens for the fb pool.
        address fbToken0 = Currency.unwrap(fbKey.currency0);
        address fbToken1 = Currency.unwrap(fbKey.currency1);
        address origin0 = IFewWrappedToken(fbToken0).token();
        address origin1 = IFewWrappedToken(fbToken1).token();

        MockERC20(origin0).approve(fbToken0, type(uint256).max);
        MockERC20(origin1).approve(fbToken1, type(uint256).max);
        IFewWrappedToken(fbToken0).wrap(amount0);
        IFewWrappedToken(fbToken1).wrap(amount1);

        // Approve fewTokens for liquidity router.
        IERC20(fbToken0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(fbToken1).approve(address(liquidityRouter), type(uint256).max);

        // Also mint fewTokens to PoolManager for the hook's flash-take of output.
        // The hook takes fewOut from PoolManager during fb route settlement.
        MockERC20(origin0).approve(fbToken0, type(uint256).max);
        MockERC20(origin1).approve(fbToken1, type(uint256).max);
        // Wrap extra to give to PoolManager.
        IFewWrappedToken(fbToken0).wrap(amount0 * 100);
        IFewWrappedToken(fbToken1).wrap(amount1 * 100);
        IERC20(fbToken0).transfer(address(manager), amount0 * 100);
        IERC20(fbToken1).transfer(address(manager), amount1 * 100);

        // Use a tick range that contains the fb pool's current tick.
        // SQRT_PRICE_2_1 -> tick 6931, SQRT_PRICE_1_2 -> tick -6931, SQRT_PRICE_1_1 -> tick 0.
        // We use a range centered on 0 with enough width to cover all test prices.
        // Use tick spacing multiples (TICK_SPACING=10).
        // Range -7000 to 7000 covers ticks -6931 and 6931.
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -7000, tickUpper: 7000, liquidityDelta: int128(int256(liquidityAmount)), salt: 0
        });
        liquidityRouter.modifyLiquidity(fbKey, params, bytes(""));
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return _swapAsUser(zeroForOne, amountSpecified, bytes(""));
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        return swapRouter.swap(
            curKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            hookData
        );
    }

    function _fallbackData(uint256 amountLimit) internal view returns (bytes memory) {
        return abi.encode(block.timestamp + 1 hours, amountLimit);
    }

    /// @dev Returns the fb pool sqrtPriceX96 that makes fb better for zeroForOne.
    ///      When orderAligned: fb needs higher sqrtPrice -> SQRT_PRICE_2_1.
    ///      When !orderAligned: fb needs lower sqrtPrice (inverts to higher) -> SQRT_PRICE_1_2.
    function _fbPriceForBetterZeroForOne() internal view returns (uint160) {
        return orderAligned ? SQRT_PRICE_2_1 : SQRT_PRICE_1_2;
    }

    /// @dev Returns the fb pool sqrtPriceX96 that makes fb better for oneForZero.
    ///      When orderAligned: fb needs lower sqrtPrice -> SQRT_PRICE_1_2.
    ///      When !orderAligned: fb needs higher sqrtPrice (inverts to lower) -> SQRT_PRICE_2_1.
    function _fbPriceForBetterOneForZero() internal view returns (uint160) {
        return orderAligned ? SQRT_PRICE_1_2 : SQRT_PRICE_2_1;
    }
}
