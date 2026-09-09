// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {RingFallbackHook} from "../src/RingFallbackHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

/// @notice Deploys RingFallbackHook via CREATE2. Does NOT initialize any pool --
///         the cur A/B pool is initialized separately by the LP who chooses the price.
///
/// Required:
///   HOOK_SALT, EXPECTED_HOOK_ADDRESS
///
/// Optional Ethereum defaults:
///   V4_POOL_MANAGER, FEW_FACTORY, WETH9
contract DeployRingFallbackHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant V4_POOL_MANAGER_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH9_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        address poolManagerAddress = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address factoryAddress = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address wethAddress = vm.envOr("WETH9", WETH9_DEFAULT);
        bytes32 salt = vm.envBytes32("HOOK_SALT");
        address payable expectedHook = payable(vm.envAddress("EXPECTED_HOOK_ADDRESS"));

        bytes memory constructorArgs =
            abi.encode(IPoolManager(poolManagerAddress), IFewFactory(factoryAddress), IWETH9(wethAddress));
        bytes memory initCode = abi.encodePacked(type(RingFallbackHook).creationCode, constructorArgs);
        address predicted = HookMiner.computeAddress(CREATE2_DEPLOYER, uint256(salt), initCode);
        require(predicted == expectedHook, "salt/init-code address mismatch");
        require(uint160(address(expectedHook)) & Hooks.ALL_HOOK_MASK == _flags(), "wrong hook permission bits");

        vm.startBroadcast();
        if (expectedHook.code.length == 0) {
            (bool deployed,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
            require(deployed, "CREATE2 deployment failed");
        }
        require(expectedHook.code.length != 0, "hook bytecode missing");

        RingFallbackHook hook = RingFallbackHook(expectedHook);
        require(address(hook.poolManager()) == poolManagerAddress, "deployed manager mismatch");
        require(address(hook.fewFactory()) == factoryAddress, "deployed factory mismatch");
        require(address(hook.weth()) == wethAddress, "deployed weth mismatch");
        vm.stopBroadcast();

        console2.log("=== RingFallbackHook deployment verified ===");
        console2.log("Hook:        ", expectedHook);
        console2.log("poolManager: ", poolManagerAddress);
        console2.log("fewFactory:  ", factoryAddress);
        console2.log("weth9:       ", wethAddress);
        console2.log("No pool initialization is performed by this script.");
        console2.log("Initialize the cur A/B pool separately with the desired price.");
    }

    function _flags() internal pure returns (uint160) {
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    }
}
