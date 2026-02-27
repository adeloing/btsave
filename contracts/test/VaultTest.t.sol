// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import "../src/TurboPaperBoatVault.sol";
import "../src/OracleManager.sol";
import "../src/NFTCycleRewards.sol";
import "../src/StrategyHybridAccumulator.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing
 */
contract MockERC20 is ERC20Upgradeable {
    uint8 private _decimals;

    function initialize(string memory name, string memory symbol, uint8 decimals_) external initializer {
        __ERC20_init(name, symbol);
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/**
 * @title MockChainlinkFeed
 * @notice Mock Chainlink price feed for testing
 */
contract MockChainlinkFeed {
    int256 public price;
    uint8 public decimals;
    uint256 public updatedAt;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setStalePrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp - 2 hours; // Make it stale
    }
}

/**
 * @title MockVRFCoordinator
 * @notice Mock VRF coordinator for testing
 */
contract MockVRFCoordinator {
    uint256 private _requestIdCounter = 1;
    
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId) {
        requestId = _requestIdCounter++;
        
        // Simulate VRF callback with mock random number
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = uint256(keccak256(abi.encodePacked(block.timestamp, requestId))); 
        
        NFTCycleRewards(msg.sender).fulfillRandomWords(requestId, randomWords);
        
        return requestId;
    }
}

/**
 * @title VaultTest
 * @notice Comprehensive tests for the Turbo Paper Boat Vault ecosystem
 */
contract VaultTest is Test {
    /* ========== TEST CONTRACTS ========== */
    
    TurboPaperBoatVault public vault;
    OracleManager public oracle;
    NFTCycleRewards public nft;
    StrategyHybridAccumulator public strategy;
    
    MockERC20 public usdc;
    MockERC20 public wbtc;
    MockERC20 public aUsdc;
    MockERC20 public aWbtc;
    MockChainlinkFeed public btcFeed;
    MockVRFCoordinator public vrfCoordinator;

    /* ========== TEST ADDRESSES ========== */
    
    address public deployer = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public treasury = address(0x4);
    address public nftPool = address(0x5);

    /* ========== SETUP ========== */

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy mock tokens
        usdc = new MockERC20();
        usdc.initialize("USD Coin", "USDC", 6);
        
        wbtc = new MockERC20();
        wbtc.initialize("Wrapped Bitcoin", "WBTC", 8);
        
        aUsdc = new MockERC20();
        aUsdc.initialize("Aave USDC", "aUSDC", 6);
        
        aWbtc = new MockERC20();
        aWbtc.initialize("Aave WBTC", "aWBTC", 8);

        // Deploy mock Chainlink feed (BTC at $50,000)
        btcFeed = new MockChainlinkFeed(50000e8, 8);

        // Deploy mock VRF coordinator
        vrfCoordinator = new MockVRFCoordinator();

        // Deploy implementations
        TurboPaperBoatVault vaultImpl = new TurboPaperBoatVault();
        OracleManager oracleImpl = new OracleManager();
        NFTCycleRewards nftImpl = new NFTCycleRewards();
        StrategyHybridAccumulator strategyImpl = new StrategyHybridAccumulator();

        // Deploy Oracle proxy
        bytes memory oracleInitData = abi.encodeWithSelector(
            OracleManager.initialize.selector,
            address(btcFeed),
            address(0), // Strategy set later
            50000e18    // Initial ATH
        );
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), oracleInitData);
        oracle = OracleManager(address(oracleProxy));

        // Deploy NFT proxy
        bytes memory nftInitData = abi.encodeWithSelector(
            NFTCycleRewards.initialize.selector,
            "Turbo Paper Boat NFT",
            "TPB-NFT",
            address(vrfCoordinator),
            keccak256("test"),
            1
        );
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(nftImpl), nftInitData);
        nft = NFTCycleRewards(address(nftProxy));

        // Deploy Strategy proxy with dummy vault address first
        bytes memory strategyInitData = abi.encodeWithSelector(
            StrategyHybridAccumulator.initialize.selector,
            address(0x1234), // Temporary address
            address(nft)
        );
        ERC1967Proxy strategyProxy = new ERC1967Proxy(address(strategyImpl), strategyInitData);
        strategy = StrategyHybridAccumulator(address(strategyProxy));

        // Deploy Vault proxy
        bytes memory vaultInitData = abi.encodeWithSelector(
            TurboPaperBoatVault.initialize.selector,
            address(usdc),
            "Turbo Paper Boat Vault",
            "TPB",
            address(oracle),
            address(strategy),
            treasury,
            nftPool,
            address(wbtc),
            address(aWbtc),
            address(aUsdc)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = TurboPaperBoatVault(address(vaultProxy));

        // Set cross-references
        oracle.setStrategy(address(strategy));
        strategy.setVault(address(vault));

        // Grant roles
        nft.grantRole(nft.MINTER_ROLE(), address(strategy));
        oracle.grantRole(oracle.KEEPER_ROLE(), deployer);
        vault.grantRole(vault.OPERATOR_ROLE(), deployer);
        strategy.grantRole(strategy.OPERATOR_ROLE(), deployer);
        strategy.grantRole(strategy.OPERATOR_ROLE(), address(oracle));

        vm.stopPrank();
    }

    /* ========== DEPOSIT TESTS ========== */

    function testDeposit() public {
        // Arrange
        uint256 depositAmount = 1000e6; // 1000 USDC
        usdc.mint(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        
        // Act
        uint256 shares = vault.deposit(depositAmount, user1);
        
        // Assert
        assertEq(shares, depositAmount); // 1:1 ratio on first deposit
        assertEq(vault.balanceOf(user1), shares);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(usdc.balanceOf(address(vault)), depositAmount);
        
        vm.stopPrank();
    }

    function testDepositWhenPaused() public {
        // Arrange
        uint256 depositAmount = 1000e6;
        usdc.mint(user1, depositAmount);
        
        vm.prank(deployer);
        vault.pause();
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        
        // Act & Assert
        vm.expectRevert("Pausable: paused");
        vault.deposit(depositAmount, user1);
        
        vm.stopPrank();
    }

    /* ========== REDEMPTION TESTS ========== */

    function testRedeemWhenWindowClosed() public {
        // Arrange - deposit first
        uint256 depositAmount = 1000e6;
        usdc.mint(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        // Redemption window should be closed when price = ATH (no band)
        btcFeed.setPrice(50000e8); // Exactly at ATH
        
        // Act & Assert
        vm.expectRevert(TurboPaperBoatVault.RedemptionWindowClosed.selector);
        vault.redeem(shares, user1, user1);
        
        vm.stopPrank();
    }

    function testRedeemWhenWindowOpen() public {
        // Arrange - deposit first
        uint256 depositAmount = 1000e6;
        usdc.mint(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        // Set price within redemption band (95% to 100% of ATH)
        btcFeed.setPrice(47500e8); // 95% of $50,000
        
        // Act
        uint256 assets = vault.redeem(shares, user1, user1);
        
        // Assert
        assertEq(assets, depositAmount);
        assertEq(vault.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(user1), depositAmount);
        
        vm.stopPrank();
    }

    /* ========== ORACLE TESTS ========== */

    function testOracleGetSpotPrice() public {
        // Test normal price
        uint256 price = oracle.getSpotPrice();
        assertEq(price, 50000e18); // $50,000 in 18 decimals
        
        // Test updated price
        btcFeed.setPrice(55000e8);
        price = oracle.getSpotPrice();
        assertEq(price, 55000e18);
    }

    function testOracleStalePrice() public {
        // Set stale price (>1 hour old)
        btcFeed.setStalePrice(50000e8);
        
        vm.expectRevert(OracleManager.PriceDataStale.selector);
        oracle.getSpotPrice();
    }

    function testOracleRedemptionWindow() public {
        // At ATH - window should be open
        btcFeed.setPrice(50000e8);
        assertTrue(oracle.isRedemptionWindowOpen());
        
        // At 95% of ATH - window should be open
        btcFeed.setPrice(47500e8);
        assertTrue(oracle.isRedemptionWindowOpen());
        
        // Below 95% of ATH - window should be closed
        btcFeed.setPrice(47000e8);
        assertFalse(oracle.isRedemptionWindowOpen());
        
        // Above ATH - window should be closed
        btcFeed.setPrice(51000e8);
        assertFalse(oracle.isRedemptionWindowOpen());
    }

    /* ========== ATH UPDATE TESTS ========== */

    function testUpdateATH() public {
        // Arrange - set price above current ATH
        btcFeed.setPrice(55000e8); // $55,000 > $50,000 ATH
        
        // Act
        vm.prank(deployer);
        oracle.updateATH();
        
        // Assert
        assertEq(oracle.currentATH(), 55000e18);
        assertEq(oracle.athUpdateCount(), 1);
        
        // Check that strategy cycle was reset
        (uint256 cycleCount, bool active,) = strategy.currentCycle();
        assertEq(cycleCount, 1);
        assertTrue(active);
    }

    function testUpdateATHFailsWhenPriceNotHigher() public {
        // Price equal to ATH
        btcFeed.setPrice(50000e8);
        
        vm.prank(deployer);
        vm.expectRevert(OracleManager.PriceNotHigherThanATH.selector);
        oracle.updateATH();
        
        // Price below ATH  
        btcFeed.setPrice(49000e8);
        
        vm.prank(deployer);
        vm.expectRevert(OracleManager.PriceNotHigherThanATH.selector);
        oracle.updateATH();
    }

    /* ========== CYCLE RESET TESTS ========== */

    function testCycleReset() public {
        // Arrange
        uint256 initialCycleCount = strategy.cycleCount();
        
        // Act
        vm.prank(deployer);
        strategy.resetCycle();
        
        // Assert
        assertEq(strategy.cycleCount(), initialCycleCount + 1);
        assertTrue(strategy.cycleActive());
    }

    function testFullCycleResetFlow() public {
        // Arrange - deposit some funds first
        uint256 depositAmount = 1000e6;
        usdc.mint(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Simulate aToken balances
        aUsdc.mint(address(vault), 100e6); // Some USDC yield
        
        // Set new ATH and trigger reset
        btcFeed.setPrice(60000e8); // New ATH at $60,000
        
        vm.prank(deployer);
        oracle.updateATH();
        
        // Assert oracle was updated
        assertEq(oracle.currentATH(), 60000e18);
        assertEq(oracle.athUpdateCount(), 1);
        
        // Assert strategy cycle was incremented
        (uint256 cycleCount, bool active,) = strategy.currentCycle();
        assertEq(cycleCount, 1);
        assertTrue(active);
    }

    /* ========== NFT TESTS ========== */

    function testNFTMinting() public {
        // Act
        vm.prank(deployer);
        uint256 requestId = nft.requestMint(user1, 150e6); // Above 100 USDC threshold
        
        // Assert NFT was minted (mock VRF fulfills immediately)
        assertEq(nft.balanceOf(user1), 1);
        assertEq(nft.totalMinted(), 1);
        
        // Check tier was assigned
        (, NFTCycleRewards.Tier tier) = nft.getNFTInfo(1);
        assertTrue(tier >= NFTCycleRewards.Tier.Bronze && tier <= NFTCycleRewards.Tier.Platinum);
    }

    function testNFTMintingInsufficientBalance() public {
        vm.prank(deployer);
        vm.expectRevert(NFTCycleRewards.InsufficientBalance.selector);
        nft.requestMint(user1, 50e6); // Below 100 USDC threshold
    }

    /* ========== HARVEST TESTS ========== */

    function testHarvest() public {
        // Arrange - deposit and simulate time passing
        uint256 depositAmount = 1000e6;
        usdc.mint(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Simulate time passing (1 year for easier calculation)
        vm.warp(block.timestamp + 365 days);
        
        // Act
        vm.prank(deployer);
        vault.harvest();
        
        // Assert management fee was collected (1% annual)
        uint256 expectedFee = depositAmount / 100; // 1%
        assertApproxEqRel(vault.balanceOf(treasury), expectedFee, 0.01e18); // 1% tolerance
    }

    /* ========== EMERGENCY FUNCTIONS TESTS ========== */

    function testEmergencyWithdrawTimelock() public {
        // Arrange
        uint256 amount = 100e6;
        usdc.mint(address(vault), amount);
        
        // Schedule withdrawal
        vm.prank(deployer);
        vault.scheduleEmergencyWithdraw(address(usdc), amount, treasury);
        
        // Try to execute immediately (should fail)
        bytes32 withdrawalId = keccak256(abi.encodePacked(address(usdc), amount, treasury, block.timestamp));
        vm.prank(deployer);
        vm.expectRevert(TurboPaperBoatVault.EmergencyWithdrawTooEarly.selector);
        vault.executeEmergencyWithdraw(withdrawalId);
        
        // Wait for timelock to pass
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Execute withdrawal (should succeed)
        vm.prank(deployer);
        vault.executeEmergencyWithdraw(withdrawalId);
        
        assertEq(usdc.balanceOf(treasury), amount);
    }

    /* ========== HELPER FUNCTIONS ========== */

    function testVaultTotalAssets() public {
        // Test with no positions
        assertEq(vault.totalAssets(), 0);
        
        // Add vault cash
        usdc.mint(address(vault), 500e6);
        assertEq(vault.totalAssets(), 500e6);
        
        // Add aUSDC balance
        aUsdc.mint(address(vault), 200e6);
        assertEq(vault.totalAssets(), 700e6); // 500 + 200
        
        // Add aWBTC balance (should be converted to USDC via oracle)
        aWbtc.mint(address(vault), 1e8); // 1 WBTC
        // 1 WBTC * $50,000 / 100 (8 to 6 decimals) = 500 USDC
        assertEq(vault.totalAssets(), 1200e6); // 500 + 200 + 500
        
        // Add Deribit balance
        vm.prank(deployer);
        vault.updateDeribitBalance(100e6);
        assertEq(vault.totalAssets(), 1300e6); // 500 + 200 + 500 + 100
    }

    function testPricePerShare() public {
        // Initial price should be 1e18 (1.0)
        assertEq(vault.pricePerShare(), 1e18);
        
        // Deposit 1000 USDC
        uint256 depositAmount = 1000e6;
        usdc.mint(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Price should still be 1.0
        assertEq(vault.pricePerShare(), 1e18);
        
        // Add yield (simulate aToken appreciation)
        aUsdc.mint(address(vault), 50e6); // 5% yield
        
        // Price should increase to 1.05
        assertEq(vault.pricePerShare(), 1.05e18);
    }
}