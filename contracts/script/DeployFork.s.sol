// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/NFTBonus.sol";
import "../src/StrategyOnChain.sol";
import "../src/TurboPaperBoatVault.sol";
import "../src/AevoAdapter.sol";
import "../src/mocks/MockAevoRouter.sol";

/**
 * @title DeployFork — Deploy BTSAVE stack on Anvil fork of Arbitrum
 * @notice Uses real AAVE/GMX addresses, mock Aevo router
 */
contract DeployFork is Script {
    // Real Arbitrum addresses
    address constant AAVE_POOL    = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_ORACLE  = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address constant WBTC         = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant USDC         = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AWBTC        = 0x078f358208685046a11C85e8ad32895DED33A249;
    address constant AUSDC        = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address constant DEBT_USDC    = 0xFCCf3cAbbe80101232d343252614b6A3eE81C989;

    // GMX V2 Arbitrum
    address constant GMX_EXCHANGE_ROUTER = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;
    address constant GMX_READER          = 0xf60becbba223EEA9495Da3f606753867eC10d139;
    address constant GMX_DATA_STORE      = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_ORDER_VAULT     = 0x31Ef83A530fDe1B38DeDa89C0a6c72a85b64c199;
    bytes32 constant GMX_BTC_MARKET_KEY  = 0x00000000000000000000000047c031236e19d024b42f8AE6DA7A02043Dd4f16F;

    function run() external {
        uint256 deployerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        // 1. Deploy Mock Aevo Router
        MockAevoRouter mockAevo = new MockAevoRouter();
        console.log("MockAevoRouter:", address(mockAevo));

        // 2. Predict vault address (deployer nonce will be at +4 after NFTBonus + Strategy)
        // nonce 0 = MockAevoRouter, 1 = NFTBonus, 2 = Strategy, 3 = Vault
        uint256 currentNonce = vm.getNonce(deployer);
        // currentNonce is now nonce after MockAevoRouter deploy (1)
        // NFTBonus will be nonce 1, Strategy nonce 2, Vault nonce 3
        address predictedVault = vm.computeCreateAddress(deployer, currentNonce + 2);
        console.log("Predicted vault:", predictedVault);

        // 3. Deploy NFTBonus (vault = predicted, admin = deployer)
        NFTBonus nftBonus = new NFTBonus(predictedVault, deployer, "https://btsave.io/nft/{id}.json");
        console.log("NFTBonus:", address(nftBonus));

        // 4. Deploy Strategy (vault = predicted)
        StrategyOnChain strategy = new StrategyOnChain(
            predictedVault,
            AAVE_POOL,
            AAVE_ORACLE,
            GMX_EXCHANGE_ROUTER,
            GMX_READER,
            GMX_DATA_STORE,
            GMX_BTC_MARKET_KEY,
            GMX_ORDER_VAULT,
            WBTC,
            USDC,
            AWBTC,
            DEBT_USDC
        );
        console.log("StrategyOnChain:", address(strategy));

        // 5. Deploy Vault
        TurboPaperBoatVault vault = new TurboPaperBoatVault(
            IERC20(WBTC),
            IStrategyOnChain(address(strategy)),
            nftBonus,
            deployer,       // treasury = deployer for testing
            deployer,       // timelock = deployer for testing
            deployer        // guardian = deployer for testing
        );
        console.log("TurboPaperBoatVault:", address(vault));
        require(address(vault) == predictedVault, "Vault address mismatch!");

        // 6. Deploy AevoAdapter
        AevoAdapter aevoAdapter = new AevoAdapter(
            address(mockAevo),
            address(strategy),
            USDC,
            WBTC,
            1000e6 // 1000 USDC default premium limit
        );
        console.log("AevoAdapter:", address(aevoAdapter));

        // 7. Set up roles
        // Strategy: grant KEEPER to deployer, set AevoAdapter
        strategy.setAevoAdapter(aevoAdapter);
        // AevoAdapter: grant KEEPER to deployer (already done in constructor)

        // Grant vault admin role on strategy (vault is already set as immutable)
        // Strategy grants DEFAULT_ADMIN to deployer in constructor, KEEPER to deployer

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Deployer:", deployer);

        vm.stopBroadcast();
    }
}
