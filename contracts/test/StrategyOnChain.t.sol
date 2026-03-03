// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/StrategyOnChain.sol";
import "../src/AevoAdapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAavePool.sol";
import "./mocks/MockAaveOracle.sol";
import "./mocks/MockGMXExchangeRouter.sol";
import "./mocks/MockGMXReader.sol";
import "./mocks/MockAevoRouter.sol";
import "./mocks/MockCamelotRouter.sol";

contract StrategyOnChainTest is Test {
    StrategyOnChain strategy;
    MockERC20 wbtc;
    MockERC20 usdc;
    MockERC20 aWbtc;
    MockERC20 debtUsdc;
    MockAavePool aavePool;
    MockAaveOracle aaveOracle;
    MockGMXExchangeRouter gmxRouter;
    MockGMXReader gmxReader;
    MockAevoRouter aevoRouter;
    MockCamelotRouter camelotRouter;

    address vaultAddr = address(0xBA1);
    address keeper = address(0xBEEF);
    address admin;

    uint256 constant BTC_PRICE = 60_000e8;
    uint256 constant ONE_WBTC = 1e8;
    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        admin = address(this);

        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usdc = new MockERC20("USDC", "USDC", 6);
        aWbtc = new MockERC20("aWBTC", "aWBTC", 8);
        debtUsdc = new MockERC20("debtUSDC", "debtUSDC", 6);

        aavePool = new MockAavePool(address(wbtc), address(usdc), address(aWbtc), address(debtUsdc));
        aaveOracle = new MockAaveOracle();
        gmxRouter = new MockGMXExchangeRouter();
        gmxReader = new MockGMXReader();

        aaveOracle.setAssetPrice(address(wbtc), BTC_PRICE);

        // Fund aave pool with USDC for borrows
        usdc.mint(address(aavePool), 100_000_000 * ONE_USDC);
        // Fund aave pool with WBTC for withdrawals
        wbtc.mint(address(aavePool), 100_000 * ONE_WBTC);

        strategy = new StrategyOnChain(
            vaultAddr,
            address(aavePool),
            address(aaveOracle),
            address(gmxRouter),
            address(gmxReader),
            address(1), // dataStore
            bytes32(uint256(2)), // marketKey
            address(3), // orderVault
            address(wbtc),
            address(usdc),
            address(aWbtc),
            address(debtUsdc)
        );

        strategy.grantRole(strategy.KEEPER_ROLE(), keeper);

        // Setup camelot router with large balances
        camelotRouter = new MockCamelotRouter();
        camelotRouter.setTokens(address(wbtc), address(usdc));
        usdc.mint(address(camelotRouter), 100_000_000 * ONE_USDC);
        wbtc.mint(address(camelotRouter), 100_000 * ONE_WBTC);
        strategy.setDexRouter(address(camelotRouter));

        // Setup aevo
        aevoRouter = new MockAevoRouter(address(usdc));
        usdc.mint(address(aevoRouter), 1_000_000 * ONE_USDC);
    }

    // ==================== DEPOSIT / WITHDRAW ====================

    function test_deposit_onlyVault() public {
        wbtc.mint(vaultAddr, 10 * ONE_WBTC);
        vm.prank(vaultAddr);
        wbtc.approve(address(strategy), 10 * ONE_WBTC);

        vm.prank(vaultAddr);
        strategy.deposit(10 * ONE_WBTC);

        assertEq(aWbtc.balanceOf(address(strategy)), 10 * ONE_WBTC, "should have aWBTC");
    }

    function test_deposit_revert_notVault() public {
        vm.prank(keeper);
        vm.expectRevert(StrategyOnChain.OnlyVault.selector);
        strategy.deposit(1 * ONE_WBTC);
    }

    function test_withdraw_onlyVault() public {
        // Deposit first
        wbtc.mint(vaultAddr, 10 * ONE_WBTC);
        vm.startPrank(vaultAddr);
        wbtc.approve(address(strategy), 10 * ONE_WBTC);
        strategy.deposit(10 * ONE_WBTC);

        uint256 received = strategy.withdraw(5 * ONE_WBTC, vaultAddr);
        vm.stopPrank();

        assertEq(received, 5 * ONE_WBTC);
        assertEq(wbtc.balanceOf(vaultAddr), 5 * ONE_WBTC);
    }

    function test_withdraw_revert_notVault() public {
        vm.prank(keeper);
        vm.expectRevert(StrategyOnChain.OnlyVault.selector);
        strategy.withdraw(1, keeper);
    }

    function test_withdraw_revert_insufficientLiquidity() public {
        // No deposits, try to withdraw
        vm.prank(vaultAddr);
        vm.expectRevert(StrategyOnChain.InsufficientLiquidity.selector);
        strategy.withdraw(1 * ONE_WBTC, vaultAddr);
    }

    // ==================== ATH MANAGEMENT ====================

    function test_updateATH() public {
        vm.prank(keeper);
        strategy.updateATH(65_000e8);
        assertEq(strategy.currentATH(), 65_000e8);
    }

    function test_updateATH_ignoresLower() public {
        vm.prank(keeper);
        strategy.updateATH(60_000e8);

        vm.prank(keeper);
        strategy.updateATH(50_000e8);
        assertEq(strategy.currentATH(), 60_000e8, "ATH should not decrease");
    }

    function test_updateATH_deltaTooBig() public {
        vm.prank(keeper);
        strategy.updateATH(60_000e8);

        // Try +11% jump (> MAX_ATH_DELTA_BPS = 10%)
        vm.prank(keeper);
        vm.expectRevert();
        strategy.updateATH(66_600e8);
    }

    function test_updateATH_resetsReopenings() public {
        vm.prank(keeper);
        strategy.updateATH(60_000e8);

        // cycleReopenings should be 0 after ATH update
        assertEq(strategy.cycleReopenings(), 0);
    }

    function test_updateATH_onlyKeeper() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        strategy.updateATH(60_000e8);
    }

    // ==================== PHASE TRANSITIONS ====================

    function test_phase_startsIdle() public {
        assertEq(uint256(strategy.phase()), uint256(StrategyOnChain.Phase.IDLE));
    }

    // ==================== TOTAL ASSETS ====================

    function test_totalAssets_withDeposit() public {
        wbtc.mint(vaultAddr, 10 * ONE_WBTC);
        vm.startPrank(vaultAddr);
        wbtc.approve(address(strategy), 10 * ONE_WBTC);
        strategy.deposit(10 * ONE_WBTC);
        vm.stopPrank();

        // totalAssets = aWbtc balance - debt (no debt yet)
        uint256 ta = strategy.totalAssets();
        assertEq(ta, 10 * ONE_WBTC);
    }

    // ==================== HEALTH FACTOR ====================

    function test_getHealthFactor() public {
        aavePool.setHealthFactor(2.5e18);
        uint256 hf = strategy.getHealthFactor();
        assertEq(hf, 2.5e18);
    }

    // ==================== CASH FLOW ====================

    function test_executeCashFlow_criticalHF() public {
        // Deposit 100 WBTC to have large TVL so reserve is small relative to USDC balance
        wbtc.mint(vaultAddr, 100 * ONE_WBTC);
        vm.startPrank(vaultAddr);
        wbtc.approve(address(strategy), 100 * ONE_WBTC);
        strategy.deposit(100 * ONE_WBTC);
        vm.stopPrank();

        // Give strategy 100k USDC (simulating GMX profit) — well above 2% reserve
        // TVL ≈ 100 WBTC, reserve = 2% of (100*60000/1e10) USDC6 = 2% of 600000e6... 
        // Actually: tvlUsdc6 = (totalAssets * price) / 1e10
        // totalAssets includes the free USDC too, but aWbtc=100e8, debt=50000e6
        // Reserve target will be around 120000 USDC (2% of $6M)
        usdc.mint(address(strategy), 500_000 * ONE_USDC);
        debtUsdc.mint(address(strategy), 500_000 * ONE_USDC);

        aavePool.setHealthFactor(1.5e18);

        uint256 usdcBefore = usdc.balanceOf(address(strategy));
        vm.prank(keeper);
        strategy.executeCashFlow();

        uint256 usdcLeft = usdc.balanceOf(address(strategy));
        assertTrue(usdcLeft < usdcBefore, "should have repaid debt");
    }

    function test_executeCashFlow_moderateHF() public {
        wbtc.mint(vaultAddr, 100 * ONE_WBTC);
        vm.startPrank(vaultAddr);
        wbtc.approve(address(strategy), 100 * ONE_WBTC);
        strategy.deposit(100 * ONE_WBTC);
        vm.stopPrank();

        usdc.mint(address(strategy), 500_000 * ONE_USDC);
        debtUsdc.mint(address(strategy), 500_000 * ONE_USDC);

        aavePool.setHealthFactor(1.9e18);

        uint256 usdcBefore = usdc.balanceOf(address(strategy));
        vm.prank(keeper);
        strategy.executeCashFlow();

        uint256 usdcLeft = usdc.balanceOf(address(strategy));
        assertTrue(usdcLeft < usdcBefore, "should have used USDC");
    }

    function test_executeCashFlow_healthyHF() public {
        wbtc.mint(vaultAddr, 100 * ONE_WBTC);
        vm.startPrank(vaultAddr);
        wbtc.approve(address(strategy), 100 * ONE_WBTC);
        strategy.deposit(100 * ONE_WBTC);
        vm.stopPrank();

        usdc.mint(address(strategy), 500_000 * ONE_USDC);

        aavePool.setHealthFactor(3e18);

        uint256 usdcBefore = usdc.balanceOf(address(strategy));
        vm.prank(keeper);
        strategy.executeCashFlow();

        uint256 usdcLeft = usdc.balanceOf(address(strategy));
        assertTrue(usdcLeft < usdcBefore, "should have bought WBTC");
    }

    // ==================== ACCESS CONTROL ====================

    function test_setAevoAdapter_onlyAdmin() public {
        AevoAdapter adapter = new AevoAdapter(
            address(aevoRouter), address(strategy), address(usdc), address(wbtc), 100 * ONE_USDC
        );

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        strategy.setAevoAdapter(adapter);

        strategy.setAevoAdapter(adapter); // admin = address(this)
        assertEq(address(strategy.aevoAdapter()), address(adapter));
    }

    function test_setDexRouter_onlyAdmin() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        strategy.setDexRouter(address(0x123));

        strategy.setDexRouter(address(0x123));
        assertEq(address(strategy.dexRouter()), address(0x123));
    }

    // ==================== MANAGE POSITIONS ====================

    function test_managePositions_onlyKeeper() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        strategy.managePositions();
    }

    function test_managePositions_tracksPrice() public {
        vm.prank(keeper);
        strategy.managePositions();
        // Should not revert with no active shorts
    }

    // ==================== REBALANCING ====================

    function test_shouldRebalance_afterInterval() public {
        vm.warp(block.timestamp + 15 days);
        assertTrue(strategy.shouldRebalance());
    }

    function test_rebalance_tooSoon() public {
        // Need some balanced assets so drift is within threshold
        wbtc.mint(vaultAddr, 100 * ONE_WBTC);
        vm.startPrank(vaultAddr);
        wbtc.approve(address(strategy), 100 * ONE_WBTC);
        strategy.deposit(100 * ONE_WBTC);
        vm.stopPrank();

        // First rebalance (after interval)
        vm.warp(block.timestamp + 15 days);
        vm.prank(keeper);
        strategy.rebalance(0);

        // Second rebalance immediately should fail
        vm.prank(keeper);
        vm.expectRevert(StrategyOnChain.RebalanceTooSoon.selector);
        strategy.rebalance(0);
    }

    // ==================== VIEW FUNCTIONS ====================

    function test_currentPrice() public {
        assertEq(strategy.currentPrice(), BTC_PRICE);
    }

    function test_activeShortCount_empty() public {
        assertEq(strategy.activeShortCount(), 0);
    }

    function test_totalShorts_empty() public {
        assertEq(strategy.totalShorts(), 0);
    }

    function test_checkReopening_noLastOpen() public {
        (bool should,) = strategy.checkReopening();
        assertFalse(should);
    }
}
