// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/LimitedSignerModule.sol";

contract DeployLSM is Script {
    function run() external {
        // For Sepolia Phase 1 (observe-only), we use mock addresses
        // These will be replaced with real addresses on mainnet
        address mockSafe = vm.envOr("SAFE_ADDRESS", address(0xdead));
        address mockAavePool = vm.envOr("AAVE_POOL", address(0xdead));
        address mockOracle = vm.envOr("WBTC_ORACLE", address(0xdead));

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        LimitedSignerModule module = new LimitedSignerModule(
            mockSafe,
            mockAavePool,
            mockOracle
        );

        console.log("LimitedSignerModule deployed at:", address(module));
        console.log("Safe:", mockSafe);
        console.log("AavePool:", mockAavePool);
        console.log("Oracle:", mockOracle);

        vm.stopBroadcast();
    }
}
