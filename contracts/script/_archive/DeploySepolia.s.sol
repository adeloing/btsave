// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/TurboPaperBoatVault.sol";
import "../src/OracleManager.sol";
import "../src/NFTCycleRewards.sol";
import "../src/StrategyHybridAccumulator.sol";
import "../src/mocks/MockERC20.sol";

contract DeploySepolia is Script {
    // Sepolia Chainlink
    address constant BTC_USD_FEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant VRF_COORDINATOR = 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625;
    bytes32 constant VRF_KEY_HASH = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;
    uint64 constant VRF_SUB_ID = 0; // Will need to be created

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(pk);

        // 1. Deploy mock tokens
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockERC20 aWBTC = new MockERC20("Aave WBTC", "aWBTC", 8);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        console.log("USDC:", address(usdc));
        console.log("WBTC:", address(wbtc));

        // 2. Deploy implementations
        TurboPaperBoatVault vaultImpl = new TurboPaperBoatVault();
        OracleManager oracleImpl = new OracleManager();
        NFTCycleRewards nftImpl = new NFTCycleRewards();
        StrategyHybridAccumulator stratImpl = new StrategyHybridAccumulator();

        // 3. Deploy Oracle proxy
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeWithSelector(
                OracleManager.initialize.selector,
                BTC_USD_FEED,
                address(0), // strategy set later
                90000e18    // initial ATH $90,000
            )
        );
        console.log("Oracle:", address(oracleProxy));

        // 4. Deploy NFT proxy
        ERC1967Proxy nftProxy = new ERC1967Proxy(
            address(nftImpl),
            abi.encodeWithSelector(
                NFTCycleRewards.initialize.selector,
                "Turbo Paper Boat NFT",
                "TPB-NFT",
                VRF_COORDINATOR,
                VRF_KEY_HASH,
                VRF_SUB_ID
            )
        );
        console.log("NFT:", address(nftProxy));

        // 5. Deploy Strategy proxy
        ERC1967Proxy stratProxy = new ERC1967Proxy(
            address(stratImpl),
            abi.encodeWithSelector(
                StrategyHybridAccumulator.initialize.selector,
                address(0), // vault set later
                address(nftProxy)
            )
        );
        console.log("Strategy:", address(stratProxy));

        // 6. Deploy Vault proxy
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                TurboPaperBoatVault.initialize.selector,
                address(usdc),
                "Turbo Paper Boat Vault",
                "TPB",
                address(oracleProxy),
                address(stratProxy),
                deployer,           // treasury
                deployer,           // nftRewardPool
                address(wbtc),
                address(aWBTC),
                address(aUSDC)
            )
        );
        console.log("Vault:", address(vaultProxy));

        // 7. Wire cross-references
        OracleManager(address(oracleProxy)).setStrategy(address(stratProxy));
        StrategyHybridAccumulator(address(stratProxy)).setVault(address(vaultProxy));

        // 8. Setup roles
        TurboPaperBoatVault v = TurboPaperBoatVault(address(vaultProxy));
        v.grantRole(v.OPERATOR_ROLE(), deployer);
        v.grantRole(v.STRATEGIST_ROLE(), deployer);

        OracleManager o = OracleManager(address(oracleProxy));
        o.grantRole(o.KEEPER_ROLE(), deployer);

        NFTCycleRewards n = NFTCycleRewards(address(nftProxy));
        n.grantRole(n.MINTER_ROLE(), address(stratProxy));

        StrategyHybridAccumulator s = StrategyHybridAccumulator(address(stratProxy));
        s.grantRole(s.OPERATOR_ROLE(), deployer);
        s.grantRole(s.OPERATOR_ROLE(), address(oracleProxy));

        // 9. Mint test tokens to deployer
        usdc.mint(deployer, 100_000e6);  // 100k USDC
        wbtc.mint(deployer, 5e8);         // 5 WBTC
        aWBTC.mint(address(vaultProxy), 4e8);   // 4 aWBTC in vault (simulate Aave)
        aUSDC.mint(address(vaultProxy), 15_000e6); // 15k aUSDC in vault

        vm.stopBroadcast();

        console.log("\n=== DEPLOY COMPLETE ===");
        console.log("USDC:", address(usdc));
        console.log("WBTC:", address(wbtc));
        console.log("VAULT:", address(vaultProxy));
        console.log("ORACLE:", address(oracleProxy));
        console.log("NFT:", address(nftProxy));
        console.log("STRATEGY:", address(stratProxy));
    }
}
