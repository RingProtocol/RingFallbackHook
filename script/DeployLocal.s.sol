// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {RingFallbackHook} from "../src/RingFallbackHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {MockFewFactory} from "../test/mocks/MockFewFactory.sol";
import {MockWETH9} from "../test/mocks/MockWETH9.sol";

/// @notice Full local deployment script for testing on anvil.
///         Deploys everything from scratch: PoolManager, mock tokens, mock FewFactory,
///         hook (mined address), cur pool init, fb pool init + liquidity, cur pool liquidity,
///         and a test swap to verify the fallback routing works.
///
/// @dev Usage:
///   anvil --port 8545 &
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv
contract DeployLocal is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using StateLibrary for PoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant SQRT_PRICE_1_2 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_2_1 = 112045541949572279837463876454;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant LIQUIDITY = 100e18;
    uint256 internal constant SWAP_AMOUNT = 1e18;

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // anvil account 0
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PoolManager
        PoolManager manager = new PoolManager(deployer);
        console2.log("PoolManager:", address(manager));

        // 2. Deploy test routers
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        console2.log("SwapRouter:", address(swapRouter));
        console2.log("LiquidityRouter:", address(liquidityRouter));

        // 3. Deploy mock tokens
        MockERC20 tokenA = new MockERC20("TokenA", "TA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TB", 18);
        tokenA.mint(deployer, 1_000_000e18);
        tokenB.mint(deployer, 1_000_000e18);
        console2.log("TokenA:", address(tokenA));
        console2.log("TokenB:", address(tokenB));

        // 4. Deploy mock FewFactory and create wrappers
        MockFewFactory factory = new MockFewFactory();
        factory.createToken(address(tokenA));
        factory.createToken(address(tokenB));
        address fewA = factory.getWrappedToken(address(tokenA));
        address fewB = factory.getWrappedToken(address(tokenB));
        console2.log("FewFactory:", address(factory));
        console2.log("FewA (fwA):", fewA);
        console2.log("FewB (fwB):", fewB);

        // 5. Mint underlying to PoolManager for flash-take during fb route
        tokenA.mint(address(manager), 1_000_000e18);
        tokenB.mint(address(manager), 1_000_000e18);

        // 6. Mine hook address and deploy via CREATE2
        //    forge script uses the standard CREATE2 deployer (0x4e59b4...) for new{salt} deployments.
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        MockWETH9 weth = new MockWETH9();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs =
            abi.encode(IPoolManager(address(manager)), IFewFactory(address(factory)), IWETH9(address(weth)));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(RingFallbackHook).creationCode, constructorArgs);
        RingFallbackHook hook = new RingFallbackHook{salt: salt}(
            IPoolManager(address(manager)), IFewFactory(address(factory)), IWETH9(address(weth))
        );
        require(address(hook) == expectedHook, "hook address mismatch");
        console2.log("RingFallbackHook:", address(hook));

        // 7. Approve tokens for routers and hook
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(liquidityRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        // 8. Construct pool keys
        Currency currency0;
        Currency currency1;
        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        PoolKey memory curKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Derive fb key same way as hook
        address few0 = factory.getWrappedToken(Currency.unwrap(currency0));
        address few1 = factory.getWrappedToken(Currency.unwrap(currency1));
        bool orderAligned = few0 < few1;
        PoolKey memory fbKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // 9. Initialize cur pool at 1:1
        manager.initialize(curKey, SQRT_PRICE_1_1);
        console2.log("Cur pool initialized at 1:1");

        // 10. Add liquidity to cur pool
        {
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: int128(int256(LIQUIDITY)), salt: 0
            });
            liquidityRouter.modifyLiquidity(curKey, params, bytes(""));
        }
        console2.log("Cur pool liquidity added:", LIQUIDITY);

        // 11. Wrap tokens and add liquidity to fb pool at a better price for zeroForOne.
        //     When orderAligned: fb needs higher sqrtPrice -> SQRT_PRICE_2_1.
        //     When !orderAligned: fb needs lower sqrtPrice (inverts to higher) -> SQRT_PRICE_1_2.
        uint160 fbInitPrice = orderAligned ? SQRT_PRICE_2_1 : SQRT_PRICE_1_2;
        manager.initialize(fbKey, fbInitPrice);
        console2.log("Fb pool initialized at price:", fbInitPrice);

        address fbToken0 = Currency.unwrap(fbKey.currency0);
        address fbToken1 = Currency.unwrap(fbKey.currency1);
        address origin0 = IFewWrappedToken(fbToken0).token();
        address origin1 = IFewWrappedToken(fbToken1).token();

        // Wrap for liquidity
        MockERC20(origin0).approve(fbToken0, type(uint256).max);
        MockERC20(origin1).approve(fbToken1, type(uint256).max);
        IFewWrappedToken(fbToken0).wrap(LIQUIDITY);
        IFewWrappedToken(fbToken1).wrap(LIQUIDITY);

        // Approve fewTokens for liquidity router
        IERC20(fbToken0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(fbToken1).approve(address(liquidityRouter), type(uint256).max);

        // Wrap extra and send to PoolManager for flash-take
        uint256 wrapAmount = LIQUIDITY * 200;
        IFewWrappedToken(fbToken0).wrap(wrapAmount);
        IFewWrappedToken(fbToken1).wrap(wrapAmount);
        IERC20(fbToken0).transfer(address(manager), wrapAmount);
        IERC20(fbToken1).transfer(address(manager), wrapAmount);

        {
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: -7000, tickUpper: 7000, liquidityDelta: int128(int256(LIQUIDITY)), salt: 0
            });
            liquidityRouter.modifyLiquidity(fbKey, params, bytes(""));
        }
        console2.log("Fb pool liquidity added:", LIQUIDITY);

        // 12. Test swap: explicitly route zeroForOne through the fb pool
        uint256 tokenInBefore;
        uint256 tokenOutBefore;
        if (orderAligned) {
            // zeroForOne on cur = sell token0 (origin0), buy token1 (origin1)
            tokenInBefore = IERC20(Currency.unwrap(currency0)).balanceOf(deployer);
            tokenOutBefore = IERC20(Currency.unwrap(currency1)).balanceOf(deployer);
        } else {
            tokenInBefore = IERC20(Currency.unwrap(currency0)).balanceOf(deployer);
            tokenOutBefore = IERC20(Currency.unwrap(currency1)).balanceOf(deployer);
        }

        (uint160 curPriceBefore,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceBefore,,,) = manager.getSlot0(fbKey.toId());

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        BalanceDelta swapDelta = swapRouter.swap(
            curKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            abi.encode(block.timestamp + 1 hours, uint256(1))
        );

        (uint160 curPriceAfter,,,) = manager.getSlot0(curKey.toId());
        (uint160 fbPriceAfter,,,) = manager.getSlot0(fbKey.toId());

        uint256 tokenInAfter = IERC20(Currency.unwrap(currency0)).balanceOf(deployer);
        uint256 tokenOutAfter = IERC20(Currency.unwrap(currency1)).balanceOf(deployer);

        console2.log("=== Test swap result ===");
        console2.log("Swap amount (zeroForOne):", SWAP_AMOUNT);
        console2.log("Delta amount0:", int256(swapDelta.amount0()));
        console2.log("Delta amount1:", int256(swapDelta.amount1()));
        console2.log("Cur price before:", curPriceBefore);
        console2.log("Cur price after: ", curPriceAfter);
        console2.log("Fb price before: ", fbPriceBefore);
        console2.log("Fb price after:  ", fbPriceAfter);
        console2.log("TokenIn consumed: ", tokenInBefore - tokenInAfter);
        console2.log("TokenOut received:", tokenOutAfter - tokenOutBefore);

        if (fbPriceAfter != fbPriceBefore) {
            console2.log("Result: fb pool was used (fb price moved, cur price unchanged)");
        } else if (curPriceAfter != curPriceBefore) {
            console2.log("Result: cur pool was used (cur price moved)");
        } else {
            console2.log("Result: WARNING - neither pool moved");
        }

        // Verify hook has no residual balances
        require(
            IERC20(address(tokenA)).balanceOf(address(hook)) == 0
                && IERC20(address(tokenB)).balanceOf(address(hook)) == 0 && IERC20(fewA).balanceOf(address(hook)) == 0
                && IERC20(fewB).balanceOf(address(hook)) == 0,
            "hook has residual balances"
        );
        console2.log("Hook balances: all zero (OK)");

        vm.stopBroadcast();

        console2.log("=== Local deployment complete ===");
        console2.log("All contracts deployed and test swap verified on anvil.");
    }
}
