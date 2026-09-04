// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {RingFallbackHook} from "../src/RingFallbackHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

/// @notice Read-only preflight and CREATE2 address mining for RingFallbackHook.
///
/// Optional Ethereum defaults:
///   V4_POOL_MANAGER, FEW_FACTORY
contract MineRingFallbackHookAddress is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant V4_POOL_MANAGER_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;

    function run() external view {
        address poolManagerAddress = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address factoryAddress = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManagerAddress), IFewFactory(factoryAddress));
        uint160 flags = _flags();
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(RingFallbackHook).creationCode, constructorArgs);

        console2.log("=== RingFallbackHook preflight ===");
        console2.log("poolManager:  ", poolManagerAddress);
        console2.log("fewFactory:   ", factoryAddress);
        console2.log("permission mask:", flags);
        console2.log("HOOK_SALT:");
        console2.logBytes32(salt);
        console2.log("EXPECTED_HOOK_ADDRESS:", expectedHook);
    }

    function _flags() internal pure returns (uint160) {
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    }
}
