// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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

/// @notice Anvil fork test: ETH : token pair with orderAligned = true.
///         cur pool:  currency0 = ETH (address 0), currency1 = ERC20 token
///         fb pool:   currency0 = FewWETH, currency1 = FewToken  (few0 < few1 → orderAligned = true)
///         Tests exact-input and exact-output in both directions (ETH→token and token→ETH).
contract RingFallbackHookAnvilEthTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;

    uint128 internal constant CUR_LIQUIDITY = 100;
    uint128 internal constant FB_LIQUIDITY = 100_000;

    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint256 internal constant MINT = 1_000_000_000;
    uint256 internal constant SWAP_AMOUNT = 50;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FALLBACK_SWAP_TOPIC =
        keccak256("FallbackSwap(bytes32,bytes32,address,bool,bool,int256,uint256,uint256)");

    struct FbResult {
        int128 fbAmount0;
        int128 fbAmount1;
        uint160 fbPriceAfter;
        int24 fbTickAfter;
        uint128 fbLiquidityAtSwap;
        uint24 fbSwapFee;
        int128 curAmount0;
        int128 curAmount1;
        bool usedFb;
        bool fbZeroForOne;
        int256 amountSpecified;
        uint256 amountIn;
        uint256 amountOut;
    }

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    MockFewFactory internal factory;
    MockWETH9 internal weth;
    RingFallbackHook internal hook;

    // ERC20 token paired with ETH.
    MockERC20 internal token;
    // FewWETH wraps WETH; FewToken wraps token. orderAligned = true requires few0 < few1.
    address internal fewWeth;
    address internal fewToken;

    PoolKey internal curKey;
    PoolId internal curPoolId;
    PoolKey internal fbKey;
    PoolId internal fbPoolId;

    address internal USER = makeAddr("USER");

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("ANVIL_RPC_URL", string("http://127.0.0.1:8545"));
        vm.createSelectFork(rpc);

        manager = IPoolManager(V4_POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        weth = new MockWETH9();
        factory = new MockFewFactory();

        // Create FewWETH (wraps WETH).
        factory.createToken(address(weth));
        fewWeth = factory.getWrappedToken(address(weth));

        // Deploy several ERC20 tokens and create their wrappers; pick one where FewWETH < FewToken
        // so orderAligned = true.
        uint8 n = 8;
        MockERC20[] memory tokens = new MockERC20[](n);
        for (uint8 i = 0; i < n; i++) {
            tokens[i] = new MockERC20("XX", "XX", 18);
            factory.createToken(address(tokens[i]));
        }
        bool found;
        for (uint8 i = 0; i < n && !found; i++) {
            address fewT = factory.getWrappedToken(address(tokens[i]));
            if (fewWeth < fewT) {
                token = tokens[i];
                fewToken = fewT;
                found = true;
            }
        }
        require(found, "no orderAligned=true pair found");
        assertTrue(fewWeth < fewToken, "orderAligned must be true");

        // Deploy the hook at a mined address matching the 0x88 permission mask.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, IFewFactory(address(factory)), IWETH9(address(weth)));
        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(RingFallbackHook).creationCode, constructorArgs);
        hook = new RingFallbackHook{salt: salt}(manager, IFewFactory(address(factory)), IWETH9(address(weth)));
        assertEq(address(hook), minedAddr, "hook address mismatch");

        // cur pool: ETH : token. ETH is address(0), always currency0.
        curKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        curPoolId = curKey.toId();

        // fb pool: FewWETH : FewToken (orderAligned = true, same order as cur).
        fbKey = PoolKey({
            currency0: Currency.wrap(fewWeth),
            currency1: Currency.wrap(fewToken),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        fbPoolId = fbKey.toId();

        // Fund LP (this contract) with tokens and ETH.
        token.mint(address(this), MINT * 10);
        vm.deal(address(this), MINT * 10 ether);

        // cur pool: initialize at 1:1 and add liquidity 100.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: MINT * 2}(
            curKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int128(uint128(CUR_LIQUIDITY)), salt: 0
            }),
            bytes("")
        );

        // fb pool: initialize at 1:1 and add liquidity 100000.
        // Wrap WETH and token into FewTokens first.
        weth.deposit{value: MINT * 4}();
        token.mint(address(this), MINT * 4);
        weth.approve(fewWeth, type(uint256).max);
        token.approve(fewToken, type(uint256).max);
        IFewWrappedToken(fewWeth).wrap(MINT * 4);
        IFewWrappedToken(fewToken).wrap(MINT * 4);
        IERC20(fewWeth).approve(address(liquidityRouter), type(uint256).max);
        IERC20(fewToken).approve(address(liquidityRouter), type(uint256).max);
        manager.initialize(fbKey, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            fbKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int128(uint128(FB_LIQUIDITY)), salt: 0
            }),
            bytes("")
        );

        // PoolManager inventory: ETH for the hook's flash-take, FewTokens for the output leg.
        vm.deal(address(manager), MINT);
        token.mint(address(manager), MINT);
        IERC20(fewWeth).transfer(address(manager), MINT);
        IERC20(fewToken).transfer(address(manager), MINT);

        // USER: fund with ETH and tokens, approve swap router.
        vm.deal(USER, MINT * 2 ether);
        token.mint(USER, MINT);
        vm.startPrank(USER);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        console2.log("token (cur currency1):", address(token));
        console2.log("fewWeth = wrap(WETH) (fb currency0, lower):", fewWeth);
        console2.log("fewToken = wrap(token) (fb currency1, higher):", fewToken);
        console2.log("orderAligned: true (fewWeth < fewToken)");
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    /// @dev Exact-input: swap 50 ETH -> token (zeroForOne = true).
    function test_anvil_eth_exactIn_50_routesToFb() public {
        _printHeader("ETH->token exact-input 50 (zeroForOne)");

        uint256 tokBefore = token.balanceOf(USER);
        uint256 mgrFewWethBefore = IERC20(fewWeth).balanceOf(address(manager));
        uint256 mgrFewTokBefore = IERC20(fewToken).balanceOf(address(manager));

        (FbResult memory r, BalanceDelta userDelta) = _captureAndSwap(true, -int256(SWAP_AMOUNT));

        // fb swap: zeroForOne=true (orderAligned=true), so input=fb currency0 (FewWeth), output=fb currency1 (FewToken).
        int256 inputDelta = r.fbAmount0;
        int256 outputDelta = r.fbAmount1;

        console2.log("fbLiquidity:", uint256(manager.getLiquidity(fbPoolId)));
        console2.log("_executeFbSwap inputDelta  (delta.amount0):", inputDelta);
        console2.log("_executeFbSwap outputDelta (delta.amount1):", outputDelta);
        console2.log("hook amountIn  (= -inputDelta):", r.amountIn);
        console2.log("hook amountOut (= outputDelta):", r.amountOut);
        console2.log("user BalanceDelta amount0 (ETH):", int256(userDelta.amount0()));
        console2.log("user BalanceDelta amount1 (tok):", int256(userDelta.amount1()));

        assertTrue(r.usedFb, "usedFb");
        assertEq(r.amountIn, SWAP_AMOUNT, "exact-in fully filled");
        assertEq(inputDelta, -int256(r.amountIn), "inputDelta = -amountIn");
        assertEq(outputDelta, int256(r.amountOut), "outputDelta = amountOut");
        assertGt(r.amountOut, 0, "amountOut positive");

        // cur pool skipped.
        assertEq(r.curAmount0, 0, "cur delta amount0");
        assertEq(r.curAmount1, 0, "cur delta amount1");
        (uint160 curPrice,,,) = manager.getSlot0(curPoolId);
        assertEq(curPrice, SQRT_PRICE_1_1, "cur price unchanged");
        assertTrue(r.fbPriceAfter != SQRT_PRICE_1_1, "fb price moved");

        // User pays exactly 50 ETH (amount0) and receives amountOut token (amount1).
        assertEq(userDelta.amount0(), -int128(int256(SWAP_AMOUNT)), "user delta ETH");
        assertEq(userDelta.amount1(), int128(int256(r.amountOut)), "user delta token");
        assertEq(token.balanceOf(USER), tokBefore + r.amountOut, "user token received");

        _assertHookBalancesZero();
        assertEq(IERC20(fewWeth).balanceOf(address(manager)), mgrFewWethBefore + SWAP_AMOUNT, "mgr fewWeth +amountIn");
        assertEq(IERC20(fewToken).balanceOf(address(manager)), mgrFewTokBefore - r.amountOut, "mgr fewToken -amountOut");
    }

    /// @dev Exact-output: request 100 token out, paying ETH in (zeroForOne = true).
    function test_anvil_eth_exactOut_100_routesToFb() public {
        _printHeader("ETH->token exact-output 100 (zeroForOne)");

        uint256 tokBefore = token.balanceOf(USER);
        uint256 mgrFewWethBefore = IERC20(fewWeth).balanceOf(address(manager));
        uint256 mgrFewTokBefore = IERC20(fewToken).balanceOf(address(manager));

        (FbResult memory r, BalanceDelta userDelta) = _captureAndSwap(true, int256(100));

        int256 inputDelta = r.fbAmount0;
        int256 outputDelta = r.fbAmount1;

        console2.log("hook amountIn:", r.amountIn);
        console2.log("hook amountOut:", r.amountOut);
        console2.log("user delta ETH:", int256(userDelta.amount0()));
        console2.log("user delta token:", int256(userDelta.amount1()));

        assertTrue(r.usedFb, "usedFb");
        assertEq(r.amountOut, 100, "exact-out fully filled");
        assertEq(outputDelta, 100, "outputDelta = amountOut");
        assertEq(inputDelta, -int256(r.amountIn), "inputDelta = -amountIn");
        assertGt(r.amountIn, 100, "amountIn covers amount + fee");

        assertEq(r.curAmount0, 0, "cur delta amount0");
        assertEq(r.curAmount1, 0, "cur delta amount1");
        (uint160 curPrice,,,) = manager.getSlot0(curPoolId);
        assertEq(curPrice, SQRT_PRICE_1_1, "cur price unchanged");

        assertEq(userDelta.amount0(), -int128(int256(r.amountIn)), "user delta ETH");
        assertEq(userDelta.amount1(), 100, "user delta token");
        assertEq(token.balanceOf(USER), tokBefore + 100, "user token received");

        _assertHookBalancesZero();
        assertEq(IERC20(fewWeth).balanceOf(address(manager)), mgrFewWethBefore + r.amountIn, "mgr fewWeth +amountIn");
        assertEq(IERC20(fewToken).balanceOf(address(manager)), mgrFewTokBefore - 100, "mgr fewToken -amountOut");
    }

    /// @dev Exact-input: swap 50 token -> ETH (zeroForOne = false).
    function test_anvil_token_exactIn_50_routesToFb() public {
        _printHeader("token->ETH exact-input 50 (oneForZero)");

        uint256 tokBefore = token.balanceOf(USER);
        uint256 mgrFewWethBefore = IERC20(fewWeth).balanceOf(address(manager));
        uint256 mgrFewTokBefore = IERC20(fewToken).balanceOf(address(manager));

        (FbResult memory r, BalanceDelta userDelta) = _captureAndSwap(false, -int256(SWAP_AMOUNT));

        // fb swap: zeroForOne=false (orderAligned=true, curZeroForOne=false), so input=fb currency1 (FewToken), output=fb currency0 (FewWeth).
        int256 inputDelta = r.fbAmount1;
        int256 outputDelta = r.fbAmount0;

        console2.log("hook amountIn:", r.amountIn);
        console2.log("hook amountOut:", r.amountOut);
        console2.log("user delta ETH (amount0):", int256(userDelta.amount0()));
        console2.log("user delta token (amount1):", int256(userDelta.amount1()));

        assertTrue(r.usedFb, "usedFb");
        assertEq(r.amountIn, SWAP_AMOUNT, "exact-in fully filled");
        assertEq(inputDelta, -int256(r.amountIn), "inputDelta = -amountIn");
        assertEq(outputDelta, int256(r.amountOut), "outputDelta = amountOut");
        assertGt(r.amountOut, 0, "amountOut positive");

        assertEq(r.curAmount0, 0, "cur delta amount0");
        assertEq(r.curAmount1, 0, "cur delta amount1");

        // amount0 = ETH (user receives), amount1 = token (user pays).
        assertEq(userDelta.amount0(), int128(int256(r.amountOut)), "user delta ETH");
        assertEq(userDelta.amount1(), -int128(int256(SWAP_AMOUNT)), "user delta token");
        assertEq(token.balanceOf(USER), tokBefore - SWAP_AMOUNT, "user token consumed");

        _assertHookBalancesZero();
        assertEq(IERC20(fewToken).balanceOf(address(manager)), mgrFewTokBefore + SWAP_AMOUNT, "mgr fewToken +amountIn");
        assertEq(IERC20(fewWeth).balanceOf(address(manager)), mgrFewWethBefore - r.amountOut, "mgr fewWeth -amountOut");
    }

    /// @dev Exact-output: request 100 ETH out, paying token in (zeroForOne = false).
    function test_anvil_token_exactOut_100_routesToFb() public {
        _printHeader("token->ETH exact-output 100 (oneForZero)");

        uint256 tokBefore = token.balanceOf(USER);
        uint256 mgrFewWethBefore = IERC20(fewWeth).balanceOf(address(manager));
        uint256 mgrFewTokBefore = IERC20(fewToken).balanceOf(address(manager));

        (FbResult memory r, BalanceDelta userDelta) = _captureAndSwap(false, int256(100));

        int256 inputDelta = r.fbAmount1;
        int256 outputDelta = r.fbAmount0;

        console2.log("hook amountIn:", r.amountIn);
        console2.log("hook amountOut:", r.amountOut);
        console2.log("user delta ETH (amount0):", int256(userDelta.amount0()));
        console2.log("user delta token (amount1):", int256(userDelta.amount1()));

        assertTrue(r.usedFb, "usedFb");
        assertEq(r.amountOut, 100, "exact-out fully filled");
        assertEq(outputDelta, 100, "outputDelta = amountOut");
        assertEq(inputDelta, -int256(r.amountIn), "inputDelta = -amountIn");
        assertGt(r.amountIn, 100, "amountIn covers amount + fee");

        assertEq(r.curAmount0, 0, "cur delta amount0");
        assertEq(r.curAmount1, 0, "cur delta amount1");

        // amount0 = ETH (user receives 100), amount1 = token (user pays amountIn).
        assertEq(userDelta.amount0(), 100, "user delta ETH");
        assertEq(userDelta.amount1(), -int128(int256(r.amountIn)), "user delta token");
        assertEq(token.balanceOf(USER), tokBefore - r.amountIn, "user token consumed");

        _assertHookBalancesZero();
        assertEq(IERC20(fewToken).balanceOf(address(manager)), mgrFewTokBefore + r.amountIn, "mgr fewToken +amountIn");
        assertEq(IERC20(fewWeth).balanceOf(address(manager)), mgrFewWethBefore - 100, "mgr fewWeth -amountOut");
    }

    /// @dev Sanity: verify pool setup and order alignment.
    function test_anvil_setupOrderAligned() public view {
        assertEq(manager.getLiquidity(curPoolId), CUR_LIQUIDITY, "cur liquidity");
        assertEq(manager.getLiquidity(fbPoolId), FB_LIQUIDITY, "fb liquidity");
        assertTrue(fewWeth < fewToken, "orderAligned = true");
        assertEq(Currency.unwrap(curKey.currency0), address(0), "cur currency0 is ETH");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _captureAndSwap(bool zeroForOne, int256 amountSpecified)
        internal
        returns (FbResult memory r, BalanceDelta userDelta)
    {
        vm.recordLogs();
        userDelta = _swapAsUser(zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SWAP_TOPIC) {
                PoolId poolId = PoolId.wrap(logs[i].topics[1]);
                (
                    int128 amount0,
                    int128 amount1,
                    uint160 sqrtPriceX96,
                    uint128 liquidityAtSwap,
                    int24 tick,
                    uint24 swapFee
                ) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                if (PoolId.unwrap(poolId) == PoolId.unwrap(fbPoolId)) {
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook), "fb swap sender");
                    r.fbAmount0 = amount0;
                    r.fbAmount1 = amount1;
                    r.fbPriceAfter = sqrtPriceX96;
                    r.fbTickAfter = tick;
                    r.fbLiquidityAtSwap = liquidityAtSwap;
                    r.fbSwapFee = swapFee;
                } else if (PoolId.unwrap(poolId) == PoolId.unwrap(curPoolId)) {
                    r.curAmount0 = amount0;
                    r.curAmount1 = amount1;
                }
            } else if (logs[i].topics[0] == FALLBACK_SWAP_TOPIC && logs[i].emitter == address(hook)) {
                (bool fbZeroForOneEv, bool usedFb, int256 amountSpecifiedEv, uint256 amountIn, uint256 amountOut) =
                    abi.decode(logs[i].data, (bool, bool, int256, uint256, uint256));
                r.usedFb = usedFb;
                r.fbZeroForOne = fbZeroForOneEv;
                r.amountSpecified = amountSpecifiedEv;
                r.amountIn = amountIn;
                r.amountOut = amountOut;
            }
        }
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // For ETH input (zeroForOne = true, exact-input), send ETH with the call.
        uint256 value = 0;
        if (zeroForOne && amountSpecified < 0) {
            value = uint256(-amountSpecified);
        } else if (zeroForOne && amountSpecified > 0) {
            // exact-output ETH->token: user will pay ETH; send a generous amount, router refunds excess.
            value = uint256(amountSpecified) * 2;
        }
        vm.prank(USER);
        return swapRouter.swap{value: value}(
            curKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            bytes("")
        );
    }

    function _assertHookBalancesZero() internal view {
        assertEq(address(hook).balance, 0, "hook ETH balance");
        assertEq(token.balanceOf(address(hook)), 0, "hook token balance");
        assertEq(IERC20(fewWeth).balanceOf(address(hook)), 0, "hook fewWeth balance");
        assertEq(IERC20(fewToken).balanceOf(address(hook)), 0, "hook fewToken balance");
    }

    function _printHeader(string memory label) internal view {
        console2.log("========================================");
        console2.log("Anvil ETH fork test:", label);
        console2.log("========================================");
        console2.log("cur liquidity:", uint256(manager.getLiquidity(curPoolId)));
        console2.log("fb  liquidity:", uint256(manager.getLiquidity(fbPoolId)));
    }
}
