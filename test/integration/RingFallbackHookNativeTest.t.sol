// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {RingFallbackHook} from "../../src/RingFallbackHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

import {MockFewFactory} from "../mocks/MockFewFactory.sol";
import {MockWETH9} from "../mocks/MockWETH9.sol";

/// @notice Integration tests for RingFallbackHook with native ETH as the origin currency0.
///         Origin pool: native ETH + ERC20 (tokenB). Fallback pool: FewWETH + FewB.
contract RingFallbackHookNativeTest is Test {
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

    MockERC20 internal tokenB;
    Currency internal currencyETH;
    Currency internal currencyB;

    address internal fewWETH;
    address internal fewB;

    PoolKey internal curKey;
    PoolKey internal fbKey;
    bool internal orderAligned;

    address internal LP = makeAddr("LP");
    address internal USER = makeAddr("USER");

    /// @dev Required to receive ETH refunds from swap/liquidity routers.
    receive() external payable {}

    function setUp() public {
        // Deploy fresh PoolManager and test routers.
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy mock WETH9.
        weth = new MockWETH9();

        // Deploy mock ERC20 token (the non-native side).
        tokenB = new MockERC20("TokenB", "TB", 18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenB.mint(USER, 100e18);

        currencyETH = Currency.wrap(address(0));
        currencyB = Currency.wrap(address(tokenB));

        // Native ETH is always currency0 (address(0) < any ERC20).
        // Deploy mock FewFactory and create wrappers for WETH and tokenB.
        factory = new MockFewFactory();
        factory.createToken(address(weth));
        factory.createToken(address(tokenB));
        fewWETH = factory.getWrappedToken(address(weth));
        fewB = factory.getWrappedToken(address(tokenB));

        // Mint tokenB to PoolManager for flash-take during fb route.
        tokenB.mint(address(manager), 1_000_000e18);
        // Provide native ETH to PoolManager for flash-take.
        vm.deal(address(manager), 1_000_000e18);
        // Provide native ETH to the test contract for liquidity provision and wrapping.
        vm.deal(address(this), 1_000_000e18);

        // Deploy the hook at a mined address matching permission flags.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, IFewFactory(address(factory)), IWETH9(address(weth)));
        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(RingFallbackHook).creationCode, constructorArgs);
        hook = new RingFallbackHook{salt: salt}(manager, IFewFactory(address(factory)), IWETH9(address(weth)));
        assertEq(address(hook), minedAddr, "hook address mismatch");

        // Approve tokenB for routers.
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);

        // Approve tokenB for the hook (needed for wrap during fb route).
        tokenB.approve(address(hook), type(uint256).max);

        // User approvals.
        vm.startPrank(USER);
        tokenB.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Deal ETH to USER for swaps.
        vm.deal(USER, 1_000e18);

        // Construct pool keys. Native ETH is always currency0.
        curKey = PoolKey({
            currency0: currencyETH,
            currency1: currencyB,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Derive fb key: few0 = getWrappedToken(WETH) (since token0=ETH maps to WETH), few1 = getWrappedToken(tokenB).
        address few0 = fewWETH;
        address few1 = fewB;
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
        assertTrue(perm.beforeSwap);
        assertTrue(perm.beforeSwapReturnDelta);
    }

    // ---------------------------------------------------------------------
    // Fallback to cur pool tests
    // ---------------------------------------------------------------------

    function test_emptyHookDataUsesCurWhenFbNotInitialized() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        assertTrue(curPriceAfter != SQRT_PRICE_1_1, "cur price moved");
    }

    // ---------------------------------------------------------------------
    // fb route tests
    // ---------------------------------------------------------------------

    function test_usesExplicitFb_zeroForOne_ethToTokenB() public {
        // zeroForOne: selling ETH (currency0), buying tokenB (currency1).
        // fb is better when fbPrice > curPrice (when orderAligned).
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

    function test_usesExplicitFb_oneForZero_tokenBToEth() public {
        // oneForZero: selling tokenB (currency1), buying ETH (currency0).
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

    function test_fbRoute_hookBalancesZero_ethToTokenB() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        // Hook should hold no residual balances.
        assertEq(address(hook).balance, 0, "hook ETH balance");
        assertEq(IERC20(address(weth)).balanceOf(address(hook)), 0, "hook WETH balance");
        assertEq(IERC20(address(tokenB)).balanceOf(address(hook)), 0, "hook tokenB balance");
        assertEq(IERC20(fewWETH).balanceOf(address(hook)), 0, "hook fewWETH balance");
        assertEq(IERC20(fewB).balanceOf(address(hook)), 0, "hook fewB balance");
    }

    function test_fbRoute_hookBalancesZero_tokenBToEth() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, _fbPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addFbLiquidity(FB_LIQUIDITY);

        _swapAsUser(false, -int256(SWAP_AMOUNT), _fallbackData(1));

        assertEq(address(hook).balance, 0, "hook ETH balance");
        assertEq(IERC20(address(weth)).balanceOf(address(hook)), 0, "hook WETH balance");
        assertEq(IERC20(address(tokenB)).balanceOf(address(hook)), 0, "hook tokenB balance");
        assertEq(IERC20(fewWETH).balanceOf(address(hook)), 0, "hook fewWETH balance");
        assertEq(IERC20(fewB).balanceOf(address(hook)), 0, "hook fewB balance");
    }

    function test_autoRoutesToFbForExactOutput_ethToTokenB() public {
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

    function test_autoRoutesToFbForExactInput_tokenBToEth() public {
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

    function test_fbDeeperButTooShallowRevertsOnPartialFill() public {
        manager.initialize(curKey, SQRT_PRICE_1_1);
        manager.initialize(fbKey, SQRT_PRICE_1_1);
        _addCurLiquidity(0.001e18);
        _addFbLiquidity(0.01e18);

        vm.expectRevert();
        _swapAsUserRaw(true, -int256(SWAP_AMOUNT), bytes(""));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _addCurLiquidity(uint256 liquidityAmount) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: int128(int256(liquidityAmount)), salt: 0
        });
        // Send generous ETH to cover native currency0 settlement; router refunds excess via take.
        liquidityRouter.modifyLiquidity{value: 1_000e18}(curKey, params, bytes(""));
    }

    function _addFbLiquidity(uint256 liquidityAmount) internal {
        uint256 amount0 = liquidityAmount;
        uint256 amount1 = liquidityAmount;

        address fbToken0 = Currency.unwrap(fbKey.currency0);
        address fbToken1 = Currency.unwrap(fbKey.currency1);
        address origin0 = IFewWrappedToken(fbToken0).token();
        address origin1 = IFewWrappedToken(fbToken1).token();

        // For FewWETH, the underlying is WETH. We need WETH to wrap.
        // Deposit ETH to WETH first, then approve and wrap.
        if (origin0 == address(weth)) {
            weth.deposit{value: amount0}();
            IERC20(origin0).approve(fbToken0, type(uint256).max);
        } else {
            MockERC20(origin0).approve(fbToken0, type(uint256).max);
        }
        if (origin1 == address(weth)) {
            weth.deposit{value: amount1}();
            IERC20(origin1).approve(fbToken1, type(uint256).max);
        } else {
            MockERC20(origin1).approve(fbToken1, type(uint256).max);
        }

        IFewWrappedToken(fbToken0).wrap(amount0);
        IFewWrappedToken(fbToken1).wrap(amount1);

        // Approve fewTokens for liquidity router.
        IERC20(fbToken0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(fbToken1).approve(address(liquidityRouter), type(uint256).max);

        // Wrap extra and send to PoolManager for flash-take of output.
        uint256 wrapAmount = liquidityAmount * 200;
        if (origin0 == address(weth)) {
            weth.deposit{value: wrapAmount}();
        }
        if (origin1 == address(weth)) {
            weth.deposit{value: wrapAmount}();
        }
        IFewWrappedToken(fbToken0).wrap(wrapAmount);
        IFewWrappedToken(fbToken1).wrap(wrapAmount);
        IERC20(fbToken0).transfer(address(manager), wrapAmount);
        IERC20(fbToken1).transfer(address(manager), wrapAmount);

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
        return _swapAsUserRaw(zeroForOne, amountSpecified, hookData);
    }

    function _swapAsUserRaw(bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // For native ETH input (zeroForOne), the user needs to send ETH with the swap call.
        uint256 ethValue = 0;
        if (zeroForOne && amountSpecified < 0) {
            // exact-input ETH -> tokenB: send enough ETH to cover the swap.
            ethValue = uint256(-amountSpecified);
        } else if (zeroForOne && amountSpecified > 0) {
            // exact-output ETH -> tokenB: send a generous amount; router refunds excess.
            ethValue = uint256(amountSpecified) * 2;
        }

        vm.prank(USER);
        return swapRouter.swap{value: ethValue}(
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

    function _fbPriceForBetterZeroForOne() internal view returns (uint160) {
        return orderAligned ? SQRT_PRICE_2_1 : SQRT_PRICE_1_2;
    }

    function _fbPriceForBetterOneForZero() internal view returns (uint160) {
        return orderAligned ? SQRT_PRICE_1_2 : SQRT_PRICE_2_1;
    }
}
