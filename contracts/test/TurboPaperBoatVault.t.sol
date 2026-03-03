// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TurboPaperBoatVault.sol";
import "../src/NFTBonus.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockStrategy.sol";

contract TurboPaperBoatVaultTest is Test {
    TurboPaperBoatVault vault;
    MockERC20 wbtc;
    MockStrategy strategy;
    NFTBonus nftBonus;

    address admin = address(0xA);
    address guardian = address(0xB);
    address treasury = address(0xC);
    address alice = address(0x1);
    address bob = address(0x2);

    uint256 constant BTC_PRICE = 60_000e8; // $60k, 8 dec
    uint256 constant ONE_WBTC = 1e8;

    function setUp() public {
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        strategy = new MockStrategy(address(wbtc));
        nftBonus = new NFTBonus(address(0), admin, "https://example.com/{id}");

        strategy.setPrice(BTC_PRICE);
        strategy.setATH(BTC_PRICE);

        vault = new TurboPaperBoatVault(
            IERC20(address(wbtc)),
            IStrategyOnChain(address(strategy)),
            nftBonus,
            treasury,
            admin,    // timelock = admin for tests
            guardian
        );

        // Update NFTBonus vault to actual vault
        vm.prank(admin);
        nftBonus.setVault(address(vault));

        // Fund alice and bob
        wbtc.mint(alice, 100 * ONE_WBTC);
        wbtc.mint(bob, 100 * ONE_WBTC);
        vm.prank(alice);
        wbtc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        wbtc.approve(address(vault), type(uint256).max);
    }

    // ==================== DEPOSIT TESTS ====================

    function test_deposit_baseFee() public {
        // Price < 95% ATH → base fee 2%
        strategy.setPrice(50_000e8);
        strategy.setATH(60_000e8);

        vm.prank(alice);
        uint256 shares = vault.deposit(10 * ONE_WBTC, alice);

        // Fee = 10 * 2% = 0.2 WBTC → treasury
        assertEq(wbtc.balanceOf(treasury), 0.2e8, "treasury should get 2% fee");
        // Strategy gets 9.8 WBTC
        assertEq(strategy.totalDeposited(), 9.8e8, "strategy should get net deposit");
        assertTrue(shares > 0, "should receive shares");
    }

    function test_deposit_athFee() public {
        // Price > 95% ATH → 5% fee
        strategy.setPrice(58_000e8); // 96.7% of 60k ATH
        strategy.setATH(60_000e8);

        vm.prank(alice);
        vault.deposit(10 * ONE_WBTC, alice);

        assertEq(wbtc.balanceOf(treasury), 0.5e8, "treasury should get 5% ATH fee");
        assertEq(strategy.totalDeposited(), 9.5e8);
    }

    function test_deposit_nftBonusDiscount() public {
        // Give alice NFTs for cycle 1 (platinum)
        vm.prank(address(vault));
        nftBonus.mintCycleNFT(alice, 1, 4); // platinum

        // Set cycle to 2 so cycle 1 counts
        vm.prank(address(vault));
        nftBonus.setCycle(2);

        // Price below 95% ATH → base 2%
        strategy.setPrice(50_000e8);

        // With 1 platinum cycle: base=10000+1200=11200, tier=17500, completion=13500 (1 eligible, 1 held)
        // multiplier = 11200 * 17500 / 10000 * 13500 / 10000 = 26460
        // effective fee = 200 * 10000 / 26460 = 75 bps (~0.75%)
        // But min fee = 50 bps

        vm.prank(alice);
        vault.deposit(10 * ONE_WBTC, alice);

        uint256 treasuryBal = wbtc.balanceOf(treasury);
        // Fee should be less than base 2% (0.2e8) due to NFT discount
        assertTrue(treasuryBal < 0.2e8, "NFT bonus should reduce fee");
        assertTrue(treasuryBal >= 0.05e8, "fee should be >= 0.5% minimum");
    }

    // ==================== WITHDRAW TESTS ====================

    function _depositAndWarp(address user, uint256 amount, uint256 warpDays) internal returns (uint256 shares) {
        strategy.setPrice(50_000e8); // below 95% ATH for 2% entry
        vm.prank(user);
        shares = vault.deposit(amount, user);
        vm.warp(block.timestamp + warpDays * 1 days);
    }

    function test_withdraw_fee_under7days() public {
        uint256 shares = _depositAndWarp(alice, 10 * ONE_WBTC, 3);

        // Exit fee: 2% (< 7 days), no drawdown
        strategy.setPrice(55_000e8); // not in drawdown
        strategy.setATH(60_000e8);

        uint256 treasuryBefore = wbtc.balanceOf(treasury);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 exitFee = wbtc.balanceOf(treasury) - treasuryBefore;
        assertTrue(exitFee > 0, "should charge exit fee");
    }

    function test_withdraw_fee_under30days() public {
        uint256 shares = _depositAndWarp(alice, 10 * ONE_WBTC, 15);

        strategy.setPrice(55_000e8);
        strategy.setATH(60_000e8);

        uint256 treasuryBefore = wbtc.balanceOf(treasury);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 exitFee = wbtc.balanceOf(treasury) - treasuryBefore;
        assertTrue(exitFee > 0, "should charge 1% exit fee");
    }

    function test_withdraw_fee_under90days() public {
        uint256 shares = _depositAndWarp(alice, 10 * ONE_WBTC, 60);

        strategy.setPrice(55_000e8);
        strategy.setATH(60_000e8);

        uint256 treasuryBefore = wbtc.balanceOf(treasury);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 exitFee = wbtc.balanceOf(treasury) - treasuryBefore;
        assertTrue(exitFee > 0, "should charge 0.5% exit fee");
    }

    function test_withdraw_noFee_after90days() public {
        uint256 shares = _depositAndWarp(alice, 10 * ONE_WBTC, 100);

        strategy.setPrice(55_000e8);
        strategy.setATH(60_000e8);

        uint256 treasuryBefore = wbtc.balanceOf(treasury);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 exitFee = wbtc.balanceOf(treasury) - treasuryBefore;
        assertEq(exitFee, 0, "no exit fee after 90 days");
    }

    function test_withdraw_drawdownBonus() public {
        uint256 shares = _depositAndWarp(alice, 10 * ONE_WBTC, 3);

        // In drawdown: price < 90% ATH
        strategy.setPrice(50_000e8); // 83% of 60k
        strategy.setATH(60_000e8);

        uint256 feeBps = vault.getExitFeeBps(alice);
        // < 7 days (200) + drawdown bonus (100) = 300 bps
        assertEq(feeBps, 300, "should add drawdown bonus");
    }

    // ==================== TRANSFER BYPASS PREVENTION ====================

    function test_transfer_resetsTimer() public {
        _depositAndWarp(alice, 10 * ONE_WBTC, 100); // 100 days → no fee

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, shares);

        // Bob's timer should be reset to now
        assertEq(vault.userDepositTime(bob), block.timestamp);
        // Bob should have exit fee (< 7 days)
        uint256 feeBps = vault.getExitFeeBps(bob);
        assertTrue(feeBps > 0, "transferred shares should have fee");
    }

    // ==================== PREVIEW FUNCTIONS ====================

    function test_previewDeposit() public {
        strategy.setPrice(50_000e8);
        strategy.setATH(60_000e8);

        // First deposit so totalSupply > 0
        vm.prank(alice);
        vault.deposit(1 * ONE_WBTC, alice);

        vm.prank(bob);
        uint256 preview = vault.previewDeposit(10 * ONE_WBTC);
        assertTrue(preview > 0);
    }

    function test_previewMint() public {
        strategy.setPrice(50_000e8);
        strategy.setATH(60_000e8);

        // First deposit
        vm.prank(alice);
        vault.deposit(1 * ONE_WBTC, alice);

        vm.prank(bob);
        uint256 assets = vault.previewMint(1e18);
        assertTrue(assets > 0);
    }

    // ==================== PAUSE ====================

    function test_pause_guardian() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(alice);
        vm.expectRevert(TurboPaperBoatVault.VaultPaused.selector);
        vault.deposit(1 * ONE_WBTC, alice);
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(guardian);
        vault.pause();

        // Guardian can't unpause
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();

        // Admin can
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pause_blocksMint() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(TurboPaperBoatVault.VaultPaused.selector);
        vault.mint(1e18, alice);
    }

    // ==================== EMERGENCY ====================

    function test_emergencyWithdraw() public {
        // Put some wbtc in the vault directly
        wbtc.mint(address(vault), 5 * ONE_WBTC);

        vm.prank(admin);
        vault.emergencyWithdraw(address(wbtc), admin, 5 * ONE_WBTC);

        assertEq(wbtc.balanceOf(admin), 5 * ONE_WBTC);
    }

    function test_emergencyWithdraw_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TurboPaperBoatVault.ZeroAddress.selector);
        vault.emergencyWithdraw(address(wbtc), address(0), 1);
    }

    function test_emergencyWithdraw_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.emergencyWithdraw(address(wbtc), alice, 1);
    }

    function test_emergencyWithdrawFromStrategy() public {
        // Deposit first
        strategy.setPrice(50_000e8);
        vm.prank(alice);
        vault.deposit(10 * ONE_WBTC, alice);

        vm.prank(admin);
        vault.emergencyWithdrawFromStrategy(5 * ONE_WBTC, admin);

        assertEq(wbtc.balanceOf(admin), 5 * ONE_WBTC);
    }

    function test_emergencyWithdrawFromStrategy_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TurboPaperBoatVault.ZeroAddress.selector);
        vault.emergencyWithdrawFromStrategy(1, address(0));
    }

    // ==================== ACCESS CONTROL ====================

    function test_setStrategy_onlyAdmin() public {
        MockStrategy newStrat = new MockStrategy(address(wbtc));

        vm.prank(alice);
        vm.expectRevert();
        vault.setStrategy(IStrategyOnChain(address(newStrat)));

        vm.prank(admin);
        vault.setStrategy(IStrategyOnChain(address(newStrat)));
        assertEq(address(vault.strategy()), address(newStrat));
    }

    function test_setStrategy_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TurboPaperBoatVault.ZeroAddress.selector);
        vault.setStrategy(IStrategyOnChain(address(0)));
    }

    function test_setTreasury_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTreasury(alice);

        vm.prank(admin);
        vault.setTreasury(alice);
        assertEq(vault.treasury(), alice);
    }

    function test_setTreasury_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TurboPaperBoatVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_setNFTBonus() public {
        vm.prank(admin);
        vault.setNFTBonus(NFTBonus(address(0))); // can disable
        assertEq(address(vault.nftBonus()), address(0));
    }

    // ==================== TOTAL ASSETS ====================

    function test_totalAssets_delegatesToStrategy() public {
        strategy.setPrice(50_000e8);
        vm.prank(alice);
        vault.deposit(10 * ONE_WBTC, alice);

        // totalAssets = strategy.totalDeposited = 9.8 WBTC (after 2% fee)
        assertEq(vault.totalAssets(), strategy.totalDeposited());
    }

    // ==================== CONSTRUCTOR CHECKS ====================

    function test_constructor_zeroStrategy() public {
        vm.expectRevert(TurboPaperBoatVault.ZeroAddress.selector);
        new TurboPaperBoatVault(
            IERC20(address(wbtc)),
            IStrategyOnChain(address(0)),
            nftBonus,
            treasury,
            admin,
            guardian
        );
    }

    function test_constructor_zeroTreasury() public {
        vm.expectRevert(TurboPaperBoatVault.ZeroAddress.selector);
        new TurboPaperBoatVault(
            IERC20(address(wbtc)),
            IStrategyOnChain(address(strategy)),
            nftBonus,
            address(0),
            admin,
            guardian
        );
    }
}
