// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/VaultTPB.sol";
import "../src/MockContracts.sol";

contract MockERC20Deploy {
    string public name_;
    uint8 public dec;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public approvals;
    uint256 public supply;

    constructor(string memory _name, uint8 _dec) { name_ = _name; dec = _dec; }
    function totalSupply() external view returns (uint256) { return supply; }
    function balanceOf(address a) external view returns (uint256) { return balances[a]; }
    function decimals() external view returns (uint8) { return dec; }
    function transfer(address to, uint256 amt) external returns (bool) {
        balances[msg.sender] -= amt;
        balances[to] += amt;
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        approvals[from][msg.sender] -= amt;
        balances[from] -= amt;
        balances[to] += amt;
        return true;
    }
    function approve(address s, uint256 amt) external returns (bool) {
        approvals[msg.sender][s] = amt;
        return true;
    }
    function mint(address to, uint256 amt) external {
        balances[to] += amt;
        supply += amt;
    }
}

contract DeployVaultTPB is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Existing Sepolia deployment
        address safeAddr = 0xC5D4397049AE8BfD7f59B37ee31169d4B8D18DfC;
        address lsmAddr = 0x40f7b06433f27B9C9C24fD5d60F2816F9344e04E;

        vm.startBroadcast(deployerKey);

        // Deploy mock tokens
        MockERC20Deploy usdc = new MockERC20Deploy("USDC", 6);
        MockERC20Deploy wbtc = new MockERC20Deploy("WBTC", 8);

        // Deploy mock Aave + Oracle (reuse types from MockContracts)
        MockAavePool aavePool = new MockAavePool();
        MockOracle oracle = new MockOracle();

        // Deploy VaultTPB
        address treasury = deployer;
        uint256 initialATH = 126_000e8; // $126,000

        VaultTPB vault = new VaultTPB(
            address(usdc),
            address(wbtc),
            address(aavePool),
            address(oracle),
            address(safeAddr),
            lsmAddr,
            treasury,
            initialATH
        );

        // Mint test tokens to deployer
        usdc.mint(deployer, 1_000_000e6);  // 1M USDC
        wbtc.mint(deployer, 10e8);          // 10 WBTC
        wbtc.mint(address(vault), 5e8);     // 5 WBTC in vault for redemptions

        // Approve vault
        usdc.approve(address(vault), type(uint256).max);

        vm.stopBroadcast();

        console.log("=== VaultTPB Deployed (Sepolia) ===");
        console.log("USDC:      ", address(usdc));
        console.log("WBTC:      ", address(wbtc));
        console.log("AavePool:  ", address(aavePool));
        console.log("Oracle:    ", address(oracle));
        console.log("Vault:     ", address(vault));
        console.log("Treasury:  ", treasury);
        console.log("Deployer:  ", deployer);
    }
}
