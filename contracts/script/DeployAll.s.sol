// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/VaultTPB.sol";
import "../src/NFTBonus.sol";
import "../src/LimitedSignerModule.sol";
import "../src/MockContracts.sol";

contract MockERC20D {
    string public name_;
    uint8 public dec;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public approvals;
    uint256 public supply;
    constructor(string memory _name, uint8 _dec) { name_ = _name; dec = _dec; }
    function totalSupply() external view returns (uint256) { return supply; }
    function balanceOf(address a) external view returns (uint256) { return balances[a]; }
    function decimals() external view returns (uint8) { return dec; }
    function transfer(address to, uint256 amt) external returns (bool) { balances[msg.sender] -= amt; balances[to] += amt; return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) { approvals[from][msg.sender] -= amt; balances[from] -= amt; balances[to] += amt; return true; }
    function approve(address s, uint256 amt) external returns (bool) { approvals[msg.sender][s] = amt; return true; }
    function mint(address to, uint256 amt) external { balances[to] += amt; supply += amt; }
}

contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Mock tokens
        MockERC20D usdc = new MockERC20D("USDC", 6);
        MockERC20D wbtc = new MockERC20D("WBTC", 8);

        // 2. Mock infra
        MockSafe safe = new MockSafe();
        MockAavePool aavePool = new MockAavePool();
        MockOracle oracle = new MockOracle();
        MockTarget target = new MockTarget();

        // 3. LSM Module
        LimitedSignerModule lsm = new LimitedSignerModule(
            address(safe), address(aavePool), address(oracle)
        );

        // 4. VaultTPB
        VaultTPB vault = new VaultTPB(
            address(usdc), address(wbtc), address(aavePool), address(oracle),
            address(safe), address(lsm), deployer, 126_000e8
        );

        // 5. NFTBonus
        NFTBonus nft = new NFTBonus(
            address(vault), address(safe),
            "https://ratpoison2.duckdns.org/nft/{id}.json"
        );

        // 6. Configure LSM via Safe
        safe.exec(address(lsm), abi.encodeCall(lsm.setKeeper, (deployer, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setBot, (0x70997970C51812dc3A010C7d01b50e0d17dc79C8, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setBot, (0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setBot, (0x90F79bf6EB2c4f870365E785982E1f101E93b906, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setTarget, (address(target), true, bytes32(0))));
        safe.exec(address(lsm), abi.encodeCall(lsm.setSelector, (address(target), MockTarget.doSomething.selector, true)));

        // 7. Set NFT in vault
        safe.exec(address(vault), abi.encodeCall(vault.setNFTContract, (address(nft))));

        // 8. Mint test tokens
        usdc.mint(deployer, 1_000_000e6);
        wbtc.mint(deployer, 10e8);
        wbtc.mint(address(vault), 5e8);
        usdc.approve(address(vault), type(uint256).max);

        vm.stopBroadcast();

        console.log("=== Full Deployment (Sepolia) ===");
        console.log("Safe:      ", address(safe));
        console.log("AavePool:  ", address(aavePool));
        console.log("Oracle:    ", address(oracle));
        console.log("Target:    ", address(target));
        console.log("USDC:      ", address(usdc));
        console.log("WBTC:      ", address(wbtc));
        console.log("LSM:       ", address(lsm));
        console.log("Vault:     ", address(vault));
        console.log("NFTBonus:  ", address(nft));
        console.log("Keeper:    ", deployer);
    }
}
