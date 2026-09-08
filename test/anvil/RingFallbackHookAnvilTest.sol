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

import {MockFewFactory} from "../mocks/MockFewFactory.sol";

/// @notice Tests run against a live anvil mainnet fork (default http://127.0.0.1:8545).
///         Scenario required by the audit walkthrough:
///         - origin pool (cur) token order is REVERSED relative to the FewToken pool (fb):
///             cur:  token0 (lower address) / token1 (higher address)
///             fb:   currency0 = wrap(token1) (lower address) / currency1 = wrap(token0)
///           i.e. few0 > few1, so the hook derives orderAligned = false.
///           (mirrors the example: origin 0x000.. wrapped as 0xfff.., origin 0xabc.. wrapped as 0x1234..)
///         - cur pool liquidity = 100, fb pool liquidity = 100000, so fb is strictly deeper and is chosen.
///         - exact-input 50 and exact-output 100 swaps, capturing:
///             _executeFbSwap inputDelta / outputDelta (via the PoolManager Swap event of the fb pool),
///             the BeforeSwapDelta specifiedDelta / unspecifiedDelta returned by the hook,
///             and fbLiquidity as read at src/RingFallbackHook.sol:205.
contract RingFallbackHookAnvilTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;

    uint128 internal constant CUR_LIQUIDITY = 100;
    uint128 internal constant FB_LIQUIDITY = 100_000;

    // Real mainnet v4 PoolManager (anvil fork).
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint256 internal constant MINT = 1_000_000_000;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FALLBACK_SWAP_TOPIC =
        keccak256("FallbackSwap(bytes32,bytes32,address,bool,bool,int256,uint256,uint256)");

    struct FbResult {
        // Deltas of the hook's internal fb swap (PoolManager Swap event, fb pool, sender = hook).
        int128 fbAmount0;
        int128 fbAmount1;
        uint160 fbPriceAfter;
        int24 fbTickAfter;
        uint128 fbLiquidityAtSwap;
        uint24 fbSwapFee;
        // Deltas of the (skipped) cur pool swap, emitted with the cur pool id.
        int128 curAmount0;
        int128 curAmount1;
        // Values from the hook's FallbackSwap event.
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
    RingFallbackHook internal hook;

    // Origin tokens of the cur pool: token0 < token1.
    MockERC20 internal token0;
    MockERC20 internal token1;
    // few0 = wrap(token0) has a HIGHER address than few1 = wrap(token1) -> orderAligned = false.
    address internal few0;
    address internal few1;

    PoolKey internal curKey;
    PoolId internal curPoolId;
    PoolKey internal fbKey;
    PoolId internal fbPoolId;

    address internal USER = makeAddr("USER");

    /// @dev Freshly created contract addresses may collide with mainnet dust holders (CREATE keeps
    ///      pre-existing wei balances). The v4 test routers refund leftover ETH to msg.sender, so accept it.
    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("ANVIL_RPC_URL", string("http://127.0.0.1:8545"));
        vm.createSelectFork(rpc);

        manager = IPoolManager(V4_POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy several origin tokens and wrappers, then pick a pair whose address ordering is
        // reversed between the origin and wrapped tokens (few0 > few1 while token0 < token1).
        uint8 n = 8;
        MockERC20[] memory tokens = new MockERC20[](n);
        factory = new MockFewFactory();
        for (uint8 i = 0; i < n; i++) {
            tokens[i] = new MockERC20("Origin", "ORG", 18);
            factory.createToken(address(tokens[i]));
        }
        bool found;
        for (uint8 i = 0; i < n && !found; i++) {
            for (uint8 j = uint8(i + 1); j < n && !found; j++) {
                address a = address(tokens[i]);
                address b = address(tokens[j]);
                address wa = factory.getWrappedToken(a);
                address wb = factory.getWrappedToken(b);
                if (a < b && wa > wb) {
                    token0 = tokens[i];
                    token1 = tokens[j];
                    few0 = wa;
                    few1 = wb;
                    found = true;
                } else if (b < a && wb > wa) {
                    token0 = tokens[j];
                    token1 = tokens[i];
                    few0 = wb;
                    few1 = wa;
                    found = true;
                }
            }
        }
        require(found, "no address-order-reversed pair found");
        assertFalse(few0 < few1, "orderAligned must be false");

        // Deploy the hook at a mined address matching the 0x88 permission mask.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, IFewFactory(address(factory)));
        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(RingFallbackHook).creationCode, constructorArgs);
        hook = new RingFallbackHook{salt: salt}(manager, IFewFactory(address(factory)));
        assertEq(address(hook), minedAddr, "hook address mismatch");

        // cur pool trades origin tokens; fb pool trades the wrapped tokens with flipped order.
        curKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        curPoolId = curKey.toId();

        fbKey = PoolKey({
            currency0: Currency.wrap(few1),
            currency1: Currency.wrap(few0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        fbPoolId = fbKey.toId();

        // Fund LP (this contract) and USER with origin tokens. The LP amount carries ample
        // headroom for rounding dust pulled when adding liquidity and wrapping.
        token0.mint(address(this), MINT * 10);
        token1.mint(address(this), MINT * 10);
        token0.mint(USER, MINT);
        token1.mint(USER, MINT);

        // cur pool: initialize at 1:1 and add liquidity 100.
        manager.initialize(curKey, SQRT_PRICE_1_1);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            curKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int128(uint128(CUR_LIQUIDITY)), salt: 0
            }),
            bytes("")
        );

        // fb pool: initialize at 1:1 and add liquidity 100000 (wrap first).
        manager.initialize(fbKey, SQRT_PRICE_1_1);
        token0.approve(few0, type(uint256).max);
        token1.approve(few1, type(uint256).max);
        // Wrap extra beyond what the fb pool itself needs: the surplus funds PoolManager inventory.
        IFewWrappedToken(few0).wrap(MINT * 2);
        IFewWrappedToken(few1).wrap(MINT * 2);
        IERC20(few0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(few1).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            fbKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int128(uint128(FB_LIQUIDITY)), salt: 0
            }),
            bytes("")
        );

        // PoolManager inventory: origin input for the hook's flash-take, fewTokens for the output leg.
        token0.mint(address(manager), MINT);
        token1.mint(address(manager), MINT);
        IERC20(few0).transfer(address(manager), MINT);
        IERC20(few1).transfer(address(manager), MINT);

        // USER approvals for the swap router.
        vm.startPrank(USER);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        console2.log("token0 (cur currency0, lower address):", address(token0));
        console2.log("token1 (cur currency1, higher address):", address(token1));
        console2.log("few0 = wrap(token0) (higher address):", few0);
        console2.log("few1 = wrap(token1) (lower address):", few1);
        console2.log("orderAligned: false (cur and fb token orders are reversed)");
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    /// @dev Exact-input swap of 50 token0 -> token1 through the cur key.
    function test_anvil_exactIn_50_routesToFb() public {
        _printHeader("exact-input 50 (zeroForOne)");

        uint256 bal0Before = token0.balanceOf(USER);
        uint256 bal1Before = token1.balanceOf(USER);
        uint256 mgrFew0Before = IERC20(few0).balanceOf(address(manager));
        uint256 mgrFew1Before = IERC20(few1).balanceOf(address(manager));

        (FbResult memory r, BalanceDelta userDelta) = _captureAndSwap(true, -int256(50));

        // fb swap was oneForZero: input = fb currency1 (few0), output = fb currency0 (few1).
        int256 inputDelta = r.fbAmount1;
        int256 outputDelta = r.fbAmount0;

        console2.log("fbLiquidity read at src line 205:", uint256(manager.getLiquidity(fbPoolId)));
        console2.log("fb active liquidity during swap (Swap event):", uint256(r.fbLiquidityAtSwap));
        console2.log("_executeFbSwap inputDelta  (delta.amount1):", inputDelta);
        console2.log("_executeFbSwap outputDelta (delta.amount0):", outputDelta);
        console2.log("hook amountIn  (= -inputDelta):", r.amountIn);
        console2.log("hook amountOut (= outputDelta):", r.amountOut);
        console2.log("beforeSwap specifiedDelta   (= -amountSpecified):", int256(50));
        console2.log("beforeSwap unspecifiedDelta (= -amountOut):", -int256(r.amountOut));
        console2.log("user BalanceDelta amount0:", int256(userDelta.amount0()));
        console2.log("user BalanceDelta amount1:", int256(userDelta.amount1()));

        // The hook routed to fb and the fb swap filled completely.
        assertTrue(r.usedFb, "usedFb");
        assertEq(r.amountIn, 50, "exact-in fully filled (amountIn)");
        assertEq(inputDelta, -int256(r.amountIn), "inputDelta = -amountIn");
        assertEq(outputDelta, int256(r.amountOut), "outputDelta = amountOut");
        assertGt(r.amountOut, 0, "amountOut positive");

        // The cur pool swap was skipped (zero delta, price unchanged).
        assertEq(r.curAmount0, 0, "cur delta amount0");
        assertEq(r.curAmount1, 0, "cur delta amount1");
        (uint160 curPrice,,,) = manager.getSlot0(curPoolId);
        assertEq(curPrice, SQRT_PRICE_1_1, "cur price unchanged");
        assertTrue(r.fbPriceAfter != SQRT_PRICE_1_1, "fb price moved");

        // User pays exactly 50 token0 and receives amountOut token1.
        assertEq(userDelta.amount0(), -50, "user delta amount0");
        assertEq(userDelta.amount1(), int128(int256(r.amountOut)), "user delta amount1");
        assertEq(token0.balanceOf(USER), bal0Before - 50, "user token0 consumed");
        assertEq(token1.balanceOf(USER), bal1Before + r.amountOut, "user token1 received");

        // Hook holds no residual balances; PoolManager few inventory shifted accordingly.
        _assertHookBalancesZero();
        assertEq(IERC20(few0).balanceOf(address(manager)), mgrFew0Before + 50, "manager few0 +amountIn");
        assertEq(IERC20(few1).balanceOf(address(manager)), mgrFew1Before - r.amountOut, "manager few1 -amountOut");
    }

    /// @dev Exact-output swap requesting exactly 100 token1 out, paying token0 in, through the cur key.
    function test_anvil_exactOut_100_routesToFb() public {
        _printHeader("exact-output 100 (zeroForOne)");

        uint256 bal0Before = token0.balanceOf(USER);
        uint256 bal1Before = token1.balanceOf(USER);
        uint256 mgrFew0Before = IERC20(few0).balanceOf(address(manager));
        uint256 mgrFew1Before = IERC20(few1).balanceOf(address(manager));

        (FbResult memory r, BalanceDelta userDelta) = _captureAndSwap(true, int256(100));

        // fb swap was oneForZero: input = fb currency1 (few0), output = fb currency0 (few1).
        int256 inputDelta = r.fbAmount1;
        int256 outputDelta = r.fbAmount0;

        console2.log("fbLiquidity read at src line 205:", uint256(manager.getLiquidity(fbPoolId)));
        console2.log("fb active liquidity during swap (Swap event):", uint256(r.fbLiquidityAtSwap));
        console2.log("_executeFbSwap inputDelta  (delta.amount1):", inputDelta);
        console2.log("_executeFbSwap outputDelta (delta.amount0):", outputDelta);
        console2.log("hook amountIn  (= -inputDelta):", r.amountIn);
        console2.log("hook amountOut (= outputDelta):", r.amountOut);
        console2.log("beforeSwap specifiedDelta   (= -amountSpecified):", -int256(100));
        console2.log("beforeSwap unspecifiedDelta (= +amountIn):", int256(r.amountIn));
        console2.log("user BalanceDelta amount0:", int256(userDelta.amount0()));
        console2.log("user BalanceDelta amount1:", int256(userDelta.amount1()));

        // The hook routed to fb and the fb swap filled completely.
        assertTrue(r.usedFb, "usedFb");
        assertEq(r.amountOut, 100, "exact-out fully filled (amountOut)");
        assertEq(outputDelta, 100, "outputDelta = amountOut");
        assertEq(inputDelta, -int256(r.amountIn), "inputDelta = -amountIn");
        assertGt(r.amountIn, 100, "amountIn covers amount + fee");

        // The cur pool swap was skipped (zero delta, price unchanged).
        assertEq(r.curAmount0, 0, "cur delta amount0");
        assertEq(r.curAmount1, 0, "cur delta amount1");
        (uint160 curPrice,,,) = manager.getSlot0(curPoolId);
        assertEq(curPrice, SQRT_PRICE_1_1, "cur price unchanged");
        assertTrue(r.fbPriceAfter != SQRT_PRICE_1_1, "fb price moved");

        // User receives exactly 100 token1 and pays amountIn token0.
        assertEq(userDelta.amount0(), -int128(int256(r.amountIn)), "user delta amount0");
        assertEq(userDelta.amount1(), 100, "user delta amount1");
        assertEq(token0.balanceOf(USER), bal0Before - r.amountIn, "user token0 consumed");
        assertEq(token1.balanceOf(USER), bal1Before + 100, "user token1 received");

        // Hook holds no residual balances; PoolManager few inventory shifted accordingly.
        _assertHookBalancesZero();
        assertEq(IERC20(few0).balanceOf(address(manager)), mgrFew0Before + r.amountIn, "manager few0 +amountIn");
        assertEq(IERC20(few1).balanceOf(address(manager)), mgrFew1Before - 100, "manager few1 -amountOut");
    }

    /// @dev Sanity: routing inputs. cur=100 < fb=100000 means fb is strictly deeper.
    function test_anvil_liquidityDepthInputs() public view {
        assertEq(manager.getLiquidity(curPoolId), CUR_LIQUIDITY, "cur liquidity");
        assertEq(manager.getLiquidity(fbPoolId), FB_LIQUIDITY, "fb liquidity");
        assertTrue(address(token0) < address(token1), "cur token order");
        assertTrue(few1 < few0, "fb token order reversed");
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
                    // The hook's internal fb swap; sender must be the hook.
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
        vm.prank(USER);
        return swapRouter.swap(
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
        assertEq(token0.balanceOf(address(hook)), 0, "hook token0 balance");
        assertEq(token1.balanceOf(address(hook)), 0, "hook token1 balance");
        assertEq(IERC20(few0).balanceOf(address(hook)), 0, "hook few0 balance");
        assertEq(IERC20(few1).balanceOf(address(hook)), 0, "hook few1 balance");
    }

    function _printHeader(string memory label) internal view {
        console2.log("========================================");
        console2.log("Anvil fork test:", label);
        console2.log("========================================");
        console2.log("cur liquidity:", uint256(manager.getLiquidity(curPoolId)));
        console2.log("fb  liquidity:", uint256(manager.getLiquidity(fbPoolId)));
    }
}
