// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/LimitedSignerModule.sol";
import "../src/MockContracts.sol";

contract DeployPhase1 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy mocks
        MockSafe safe = new MockSafe();
        MockAavePool aavePool = new MockAavePool();
        MockOracle oracle = new MockOracle();
        MockTarget target = new MockTarget();

        // 2. Deploy Module
        LimitedSignerModule module = new LimitedSignerModule(
            address(safe),
            address(aavePool),
            address(oracle)
        );

        // 3. Configure Module VIA Safe (msg.sender must be Safe)
        address botA = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address botB = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        address botC = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

        // setKeeper
        safe.exec(address(module), abi.encodeCall(module.setKeeper, (deployer, true)));
        // setBots
        safe.exec(address(module), abi.encodeCall(module.setBot, (botA, true)));
        safe.exec(address(module), abi.encodeCall(module.setBot, (botB, true)));
        safe.exec(address(module), abi.encodeCall(module.setBot, (botC, true)));
        // setTarget + selector
        safe.exec(address(module), abi.encodeCall(module.setTarget, (address(target), true, bytes32(0))));
        safe.exec(address(module), abi.encodeCall(module.setSelector, (address(target), MockTarget.doSomething.selector, true)));

        vm.stopBroadcast();

        console.log("=== Phase 1 Deployment ===");
        console.log("Safe:      ", address(safe));
        console.log("AavePool:  ", address(aavePool));
        console.log("Oracle:    ", address(oracle));
        console.log("Target:    ", address(target));
        console.log("Module:    ", address(module));
        console.log("Keeper:    ", deployer);
        console.log("Bot A:     ", botA);
        console.log("Bot B:     ", botB);
        console.log("Bot C:     ", botC);
    }
}
