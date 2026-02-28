// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/VaultTPB.sol";
import "../src/NFTBonus.sol";
import "../src/LimitedSignerModule.sol";

contract MockERC20D2 {
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

contract MockSafeD2 {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8) external returns (bool) {
        (bool s,) = to.call{value: value}(data);
        return s;
    }
    function exec(address to, bytes calldata data) external returns (bool) {
        (bool s,) = to.call(data);
        require(s, "MockSafe: exec failed"); // REVERT on failure so we see errors
        return s;
    }
    function isOwner(address) external pure returns (bool) { return false; }
    function getOwners() external view returns (address[] memory) { address[] memory o = new address[](1); o[0] = msg.sender; return o; }
}

contract MockAavePoolD2 {
    uint256 public col = 500_000e8;
    uint256 public debt = 100_000e8;
    function setData(uint256 c, uint256 d) external { col = c; debt = d; }
    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (col, debt, 0, 0, 0, 2e18);
    }
}

contract MockOracleD2 {
    int256 public price = 100_000e8;
    function setPrice(int256 p) external { price = p; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MockTargetD2 {
    uint256 public value;
    function doSomething(uint256 v) external { value = v; }
}

contract DeployAll2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20D2 usdc = new MockERC20D2("USDC", 6);
        MockERC20D2 wbtc = new MockERC20D2("WBTC", 8);
        MockSafeD2 safe = new MockSafeD2();
        MockAavePoolD2 aavePool = new MockAavePoolD2();
        MockOracleD2 oracle = new MockOracleD2();
        MockTargetD2 target = new MockTargetD2();

        LimitedSignerModule lsm = new LimitedSignerModule(
            address(safe), address(aavePool), address(oracle)
        );

        VaultTPB vault = new VaultTPB(
            address(usdc), address(wbtc), address(aavePool), address(oracle),
            address(safe), address(lsm), deployer, 126_000e8
        );

        NFTBonus nftBonus = new NFTBonus(
            address(vault), address(safe),
            "https://ratpoison2.duckdns.org/nft/{id}.json"
        );

        // Config LSM
        safe.exec(address(lsm), abi.encodeCall(lsm.setKeeper, (deployer, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setBot, (0x70997970C51812dc3A010C7d01b50e0d17dc79C8, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setBot, (0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setBot, (0x90F79bf6EB2c4f870365E785982E1f101E93b906, true)));
        safe.exec(address(lsm), abi.encodeCall(lsm.setTarget, (address(target), true, bytes32(0))));
        safe.exec(address(lsm), abi.encodeCall(lsm.setSelector, (address(target), MockTargetD2.doSomething.selector, true)));

        // Set NFT in vault
        safe.exec(address(vault), abi.encodeCall(vault.setNFTContract, (address(nftBonus))));

        // Fund
        usdc.mint(deployer, 1_000_000e6);
        wbtc.mint(deployer, 10e8);
        wbtc.mint(address(vault), 5e8);
        usdc.approve(address(vault), type(uint256).max);

        vm.stopBroadcast();

        console.log("=== FULL DEPLOY v2 ===");
        console.log("USDC:      ", address(usdc));
        console.log("WBTC:      ", address(wbtc));
        console.log("Safe:      ", address(safe));
        console.log("AavePool:  ", address(aavePool));
        console.log("Oracle:    ", address(oracle));
        console.log("Target:    ", address(target));
        console.log("LSM:       ", address(lsm));
        console.log("Vault:     ", address(vault));
        console.log("NFTBonus:  ", address(nftBonus));
        console.log("Keeper:    ", deployer);
    }
}
