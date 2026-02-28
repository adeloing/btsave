// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/TurboPaperBoatVault.sol";
import "../src/OracleManager.sol";
import "../src/NFTCycleRewards.sol";
import "../src/StrategyHybridAccumulator.sol";

/**
 * @title Deploy
 * @notice Foundry deployment script for Turbo Paper Boat Vault ecosystem
 * @dev Deploys all 4 contracts behind ERC1967 proxies with proper initialization
 */
contract Deploy is Script {
    /* ========== DEPLOYMENT ADDRESSES ========== */
    
    // Sepolia testnet addresses
    address constant SEPOLIA_BTC_USD_FEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant SEPOLIA_VRF_COORDINATOR = 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625;
    bytes32 constant SEPOLIA_VRF_KEY_HASH = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;
    uint64 constant VRF_SUBSCRIPTION_ID = 1; // Replace with actual subscription ID
    
    // Mock token addresses (replace with actual tokens on testnet)
    address constant MOCK_USDC = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // Placeholder
    address constant MOCK_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // Placeholder
    address constant MOCK_AWBTC = 0x078f358208685046a11C85e8ad32895DED33A249; // Placeholder
    address constant MOCK_AUSDC = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Placeholder

    /* ========== DEPLOYMENT STATE ========== */
    
    struct DeploymentResult {
        address vaultProxy;
        address oracleProxy;
        address nftProxy;
        address strategyProxy;
        address vaultImpl;
        address oracleImpl;
        address nftImpl;
        address strategyImpl;
    }

    /* ========== MAIN DEPLOYMENT ========== */

    function run() external returns (DeploymentResult memory result) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying with address:", deployer);
        console.log("Account balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementations
        console.log("\n=== Deploying Implementations ===");
        
        TurboPaperBoatVault vaultImpl = new TurboPaperBoatVault();
        console.log("Vault Implementation:", address(vaultImpl));
        
        OracleManager oracleImpl = new OracleManager();
        console.log("Oracle Implementation:", address(oracleImpl));
        
        NFTCycleRewards nftImpl = new NFTCycleRewards();
        console.log("NFT Implementation:", address(nftImpl));
        
        StrategyHybridAccumulator strategyImpl = new StrategyHybridAccumulator();
        console.log("Strategy Implementation:", address(strategyImpl));

        // Deploy proxies with initialization
        console.log("\n=== Deploying Proxies ===");

        // Deploy Oracle Proxy first (needed by vault)
        bytes memory oracleInitData = abi.encodeWithSelector(
            OracleManager.initialize.selector,
            SEPOLIA_BTC_USD_FEED,
            address(0), // Strategy will be set later
            50000e18   // Initial ATH: $50,000
        );
        
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl),
            oracleInitData
        );
        console.log("Oracle Proxy:", address(oracleProxy));

        // Deploy NFT Proxy
        bytes memory nftInitData = abi.encodeWithSelector(
            NFTCycleRewards.initialize.selector,
            "Turbo Paper Boat NFT",
            "TPB-NFT",
            SEPOLIA_VRF_COORDINATOR,
            SEPOLIA_VRF_KEY_HASH,
            VRF_SUBSCRIPTION_ID
        );
        
        ERC1967Proxy nftProxy = new ERC1967Proxy(
            address(nftImpl),
            nftInitData
        );
        console.log("NFT Proxy:", address(nftProxy));

        // Deploy Strategy Proxy
        bytes memory strategyInitData = abi.encodeWithSelector(
            StrategyHybridAccumulator.initialize.selector,
            address(0), // Vault will be set later
            address(nftProxy)
        );
        
        ERC1967Proxy strategyProxy = new ERC1967Proxy(
            address(strategyImpl),
            strategyInitData
        );
        console.log("Strategy Proxy:", address(strategyProxy));

        // Deploy Vault Proxy
        bytes memory vaultInitData = abi.encodeWithSelector(
            TurboPaperBoatVault.initialize.selector,
            MOCK_USDC,                    // USDC token
            "Turbo Paper Boat Vault",     // Name
            "TPB",                        // Symbol
            address(oracleProxy),         // Oracle
            address(strategyProxy),       // Strategy
            deployer,                     // Treasury
            deployer,                     // NFT reward pool (same as treasury for now)
            MOCK_WBTC,                    // WBTC token
            MOCK_AWBTC,                   // aWBTC token
            MOCK_AUSDC                    // aUSDC token
        );
        
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInitData
        );
        console.log("Vault Proxy:", address(vaultProxy));

        // Update cross-references
        console.log("\n=== Setting Cross-References ===");
        
        OracleManager(address(oracleProxy)).setStrategy(address(strategyProxy));
        console.log("Oracle strategy updated");
        
        StrategyHybridAccumulator(address(strategyProxy)).setVault(address(vaultProxy));
        console.log("Strategy vault updated");

        // Setup roles
        console.log("\n=== Setting Up Roles ===");
        
        // Grant vault roles
        TurboPaperBoatVault vault = TurboPaperBoatVault(address(vaultProxy));
        vault.grantRole(vault.OPERATOR_ROLE(), deployer);
        vault.grantRole(vault.STRATEGIST_ROLE(), deployer);
        console.log("Vault roles granted to deployer");
        
        // Grant oracle roles
        OracleManager oracle = OracleManager(address(oracleProxy));
        oracle.grantRole(oracle.KEEPER_ROLE(), deployer);
        console.log("Oracle keeper role granted to deployer");
        
        // Grant NFT roles
        NFTCycleRewards nft = NFTCycleRewards(address(nftProxy));
        nft.grantRole(nft.MINTER_ROLE(), address(strategyProxy));
        console.log("NFT minter role granted to strategy");
        
        // Grant strategy roles
        StrategyHybridAccumulator strategy = StrategyHybridAccumulator(address(strategyProxy));
        strategy.grantRole(strategy.OPERATOR_ROLE(), deployer);
        strategy.grantRole(strategy.OPERATOR_ROLE(), address(oracleProxy));
        console.log("Strategy operator roles granted");

        vm.stopBroadcast();

        // Prepare result
        result = DeploymentResult({
            vaultProxy: address(vaultProxy),
            oracleProxy: address(oracleProxy),
            nftProxy: address(nftProxy),
            strategyProxy: address(strategyProxy),
            vaultImpl: address(vaultImpl),
            oracleImpl: address(oracleImpl),
            nftImpl: address(nftImpl),
            strategyImpl: address(strategyImpl)
        });

        // Log deployment summary
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Vault Proxy:    ", result.vaultProxy);
        console.log("Oracle Proxy:   ", result.oracleProxy);
        console.log("NFT Proxy:      ", result.nftProxy);
        console.log("Strategy Proxy: ", result.strategyProxy);
        console.log("\nImplementations:");
        console.log("Vault Impl:     ", result.vaultImpl);
        console.log("Oracle Impl:    ", result.oracleImpl);
        console.log("NFT Impl:       ", result.nftImpl);
        console.log("Strategy Impl:  ", result.strategyImpl);
        
        // Save addresses to file for tests
        _saveAddresses(result);

        return result;
    }

    /* ========== HELPER FUNCTIONS ========== */

    /**
     * @notice Save deployment addresses to file for use in tests
     */
    function _saveAddresses(DeploymentResult memory result) internal {
        string memory addresses = string(abi.encodePacked(
            "VAULT_PROXY=", vm.toString(result.vaultProxy), "\n",
            "ORACLE_PROXY=", vm.toString(result.oracleProxy), "\n",
            "NFT_PROXY=", vm.toString(result.nftProxy), "\n",
            "STRATEGY_PROXY=", vm.toString(result.strategyProxy), "\n",
            "VAULT_IMPL=", vm.toString(result.vaultImpl), "\n",
            "ORACLE_IMPL=", vm.toString(result.oracleImpl), "\n",
            "NFT_IMPL=", vm.toString(result.nftImpl), "\n",
            "STRATEGY_IMPL=", vm.toString(result.strategyImpl), "\n"
        ));
        
        vm.writeFile("deployments.env", addresses);
        console.log("\nAddresses saved to deployments.env");
    }

    /**
     * @notice Verify deployment by testing basic functionality
     */
    function verifyDeployment(DeploymentResult memory result) external {
        console.log("\n=== VERIFYING DEPLOYMENT ===");
        
        TurboPaperBoatVault vault = TurboPaperBoatVault(result.vaultProxy);
        OracleManager oracle = OracleManager(result.oracleProxy);
        NFTCycleRewards nft = NFTCycleRewards(result.nftProxy);
        StrategyHybridAccumulator strategy = StrategyHybridAccumulator(result.strategyProxy);
        
        // Test vault
        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
        console.log("Vault total assets:", vault.totalAssets());
        
        // Test oracle
        try oracle.getSpotPrice() returns (uint256 price) {
            console.log("BTC price:", price);
        } catch {
            console.log("BTC price feed not available (expected on some networks)");
        }
        
        // Test NFT
        console.log("NFT name:", nft.name());
        console.log("NFT symbol:", nft.symbol());
        console.log("Total minted:", nft.totalMinted());
        
        // Test strategy
        (uint256 cycle, bool active,) = strategy.currentCycle();
        console.log("Current cycle:", cycle);
        console.log("Cycle active:", active);
        
        console.log("Verification complete!");
    }
}