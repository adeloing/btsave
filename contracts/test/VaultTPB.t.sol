// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VaultTPB.sol";
import "../src/NFTBonus.sol";

contract MockWBTC {
    string public name = "Wrapped BTC";
    string public symbol = "WBTC";
    uint8 public decimals = 8;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultTPBTest is Test {
    MockWBTC wbtc;
    VaultTPB vault;
    NFTBonus nft;

    address safe = address(0x5AFE);
    address keeper = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B0);
    address attacker = address(0xBAD);

    uint256 constant ATH = 126_000e8;
    uint256 constant ONE_BTC = 1e8;

    function setUp() public {
        wbtc = new MockWBTC();
        vault = new VaultTPB(address(wbtc), safe, keeper, ATH);
        nft = new NFTBonus(address(vault), safe, "https://btsave.io/nft/");
        vault.setNFTBonus(address(nft));
    }

    // ================================================================
    // Deposit (basic + NAV)
    // ================================================================

    function test_deposit_basic() public {
        _depositAs(alice, ONE_BTC);

        // With virtual offset, shares != exact 1:1 but close
        assertTrue(vault.balanceOf(alice) > 0, "got shares");
        assertTrue(vault.totalSupply() > 0, "supply > 0");
        assertEq(vault.pendingWBTC(), ONE_BTC, "pending");
        assertEq(wbtc.balanceOf(address(vault)), ONE_BTC, "vault WBTC");
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: zero deposit");
        vault.deposit(0);
    }

    function test_deposit_nav_based() public {
        _depositAs(alice, ONE_BTC);
        uint256 aliceShares = vault.balanceOf(alice);

        // Simulate strategy gains: vault has extra 0.5 BTC
        wbtc.mint(address(vault), ONE_BTC / 2);

        _depositAs(bob, ONE_BTC);
        uint256 bobShares = vault.balanceOf(bob);

        // Alice (early) should have more shares than Bob (late)
        assertTrue(aliceShares > bobShares, "alice > bob shares");

        // Both can redeem fair value
        uint256 aliceValue = vault.previewRedeem(aliceShares);
        uint256 bobValue = vault.previewRedeem(bobShares);
        assertTrue(aliceValue > bobValue, "alice value > bob value");
    }

    function test_deposit_nav_with_safe_assets() public {
        _depositAs(alice, ONE_BTC);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        // Strategy gains
        vm.prank(keeper);
        vault.updateSafeWBTC(1.2e8);

        _depositAs(bob, ONE_BTC);

        // Bob gets fewer shares due to higher NAV
        assertTrue(vault.balanceOf(alice) > vault.balanceOf(bob), "alice > bob");
    }

    function test_deposit_multiple_users() public {
        _depositAs(alice, 2 * ONE_BTC);
        _depositAs(bob, 3 * ONE_BTC);

        assertTrue(vault.balanceOf(alice) > 0);
        assertTrue(vault.balanceOf(bob) > 0);
        assertEq(vault.totalAssets(), 5 * ONE_BTC);
    }

    // ================================================================
    // C1: First Depositor Inflation Attack Prevention
    // ================================================================

    function test_C1_inflation_attack_prevented() public {
        // Attacker deposits 1 wei
        wbtc.mint(attacker, 1);
        vm.startPrank(attacker);
        wbtc.approve(address(vault), 1);
        vault.deposit(1);
        vm.stopPrank();

        // Attacker donates 10 BTC directly to vault
        wbtc.mint(address(vault), 10 * ONE_BTC);

        // Alice deposits 1 BTC — should still get shares (virtual offset protects)
        _depositAs(alice, ONE_BTC);

        // Alice must have received non-trivial shares
        assertTrue(vault.balanceOf(alice) > 0, "alice got shares");

        // Alice's redeemable value should be close to her deposit
        uint256 aliceValue = vault.previewRedeem(vault.balanceOf(alice));
        // Should get at least 90% of deposit back (attacker can't steal more than dust)
        assertTrue(aliceValue > ONE_BTC * 90 / 100, "alice not diluted significantly");
    }

    // ================================================================
    // Transfer (ERC-20)
    // ================================================================

    function test_transfer() public {
        _depositAs(alice, ONE_BTC);
        uint256 half = vault.balanceOf(alice) / 2;

        vm.prank(alice);
        vault.transfer(bob, half);

        assertEq(vault.balanceOf(bob), half);
    }

    function test_transferFrom_with_approval() public {
        _depositAs(alice, ONE_BTC);
        uint256 bal = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, bal);

        vm.prank(bob);
        vault.transferFrom(alice, bob, bal);

        assertEq(vault.balanceOf(bob), bal);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_transfer_insufficient_reverts() public {
        _depositAs(alice, ONE_BTC);
        uint256 tooMuch = vault.balanceOf(alice) + 1;

        vm.prank(alice);
        vm.expectRevert("TPB: insufficient");
        vault.transfer(bob, tooMuch);
    }

    function test_L2_transfer_to_zero_reverts() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(alice);
        vm.expectRevert("TPB: transfer to zero");
        vault.transfer(address(0), 1);
    }

    // ================================================================
    // Redeem
    // ================================================================

    function test_redeem_at_step0() public {
        _depositAs(alice, ONE_BTC);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares / 2);

        assertTrue(wbtc.balanceOf(alice) > 0, "got WBTC back");
    }

    function test_redeem_not_step0_reverts() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(keeper);
        vault.advanceStep();

        vm.prank(alice);
        vm.expectRevert("TPB: not at step 0");
        vault.redeem(1);
    }

    function test_redeem_locked_reverts() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(keeper);
        vault.lockVault();

        vm.prank(alice);
        vm.expectRevert("TPB: locked");
        vault.redeem(1);
    }

    function test_redeem_pro_rata() public {
        _depositAs(alice, ONE_BTC);
        _depositAs(bob, ONE_BTC);

        // Simulate gains
        wbtc.mint(address(vault), ONE_BTC / 2);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares);

        // Alice should get more than 1 BTC back (her share of 2.5 BTC)
        assertTrue(wbtc.balanceOf(alice) > ONE_BTC, "alice got gains");
    }

    function test_redeem_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: zero redeem");
        vault.redeem(0);
    }

    // ================================================================
    // Pending Pool & Rebalance
    // ================================================================

    function test_rebalance_weekly() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(keeper);
        vm.expectRevert("TPB: rebalance not due");
        vault.rebalancePendingPool();

        vm.warp(block.timestamp + 7 days);

        vm.prank(keeper);
        vault.rebalancePendingPool();

        assertEq(vault.pendingWBTC(), 0, "pending cleared");
        assertEq(wbtc.balanceOf(safe), ONE_BTC, "safe received WBTC");
        assertEq(vault.safeWBTC(), ONE_BTC, "safeWBTC tracked");
    }

    function test_rebalance_threshold() public {
        _depositAs(alice, ONE_BTC);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        // Return WBTC to vault to simulate deployed TVL
        vm.prank(safe);
        wbtc.transfer(address(vault), ONE_BTC);
        vm.prank(keeper);
        vault.updateSafeWBTC(0); // returned to vault

        // Second deposit: 3% of deployed = above 2% threshold
        _depositAs(bob, ONE_BTC * 3 / 100);

        vm.prank(keeper);
        vault.rebalancePendingPool();
        assertEq(vault.pendingWBTC(), 0);
    }

    function test_rebalance_nothing_pending_reverts() public {
        vm.prank(keeper);
        vm.expectRevert("TPB: nothing pending");
        vault.rebalancePendingPool();
    }

    // ================================================================
    // Auto-Redeem
    // ================================================================

    function test_set_auto_redeem() public {
        vm.prank(alice);
        vault.setAutoRedeem(5000);
        assertEq(vault.autoRedeemBPS(alice), 5000);
    }

    function test_auto_redeem_over_max_reverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: bps > 10000");
        vault.setAutoRedeem(10001);
    }

    // ================================================================
    // Cycle: Step & Lock
    // ================================================================

    function test_advance_step() public {
        vm.prank(keeper);
        vault.advanceStep();
        assertEq(vault.currentStep(), 1);
    }

    function test_set_step() public {
        vm.prank(keeper);
        vault.advanceStep();
        vm.prank(keeper);
        vault.setStep(0);
        assertEq(vault.currentStep(), 0);
    }

    function test_lock_unlock() public {
        vm.prank(keeper);
        vault.lockVault();
        assertTrue(vault.locked());

        vm.prank(keeper);
        vault.unlockVault();
        assertFalse(vault.locked());
    }

    function test_lock_already_locked_reverts() public {
        vm.prank(keeper);
        vault.lockVault();
        vm.prank(keeper);
        vm.expectRevert("TPB: already locked");
        vault.lockVault();
    }

    function test_step_non_keeper_reverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: not keeper");
        vault.advanceStep();
    }

    // ================================================================
    // C2: End Cycle — Auto-Redeem BEFORE Rewards
    // ================================================================

    function test_end_cycle_basic() public {
        _depositAs(alice, ONE_BTC);
        _depositAs(bob, ONE_BTC);

        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;

        uint256 rewardSats = 0.1e8;

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, rewardSats, holders);

        assertTrue(vault.balanceOf(alice) > 0, "alice rewarded");
        assertTrue(vault.balanceOf(bob) > 0, "bob rewarded");
        assertEq(vault.cycleNumber(), 2);
        assertEq(vault.currentATH(), 130_000e8);
    }

    function test_C2_auto_redeem_before_rewards() public {
        _depositAs(alice, ONE_BTC);

        // Alice sets 100% auto-redeem
        vm.prank(alice);
        vault.setAutoRedeem(10000);

        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 wbtcBefore = wbtc.balanceOf(alice);

        address[] memory holders = new address[](1);
        holders[0] = alice;

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, 0.1e8, holders);

        // Alice should have received WBTC from auto-redeem at FULL value
        // (not diluted by reward mint)
        uint256 wbtcReceived = wbtc.balanceOf(alice) - wbtcBefore;
        assertTrue(wbtcReceived > 0, "alice got WBTC");

        // After auto-redeem of 100%, alice should have 0 shares
        // (rewards mint on 0 balance = no reward)
        assertEq(vault.balanceOf(alice), 0, "alice fully redeemed");
    }

    function test_end_cycle_with_nft_bonus() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(address(vault));
        nft.mintCycleNFT(alice, 1, 3); // Gold

        address[] memory holders = new address[](1);
        holders[0] = alice;

        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, 0.1e8, holders);

        assertTrue(vault.balanceOf(alice) > sharesBefore, "got reward with NFT bonus");
    }

    function test_end_cycle_ath_not_higher_reverts() public {
        address[] memory holders = new address[](0);
        vm.prank(keeper);
        vm.expectRevert("TPB: ATH not higher");
        vault.endCycleAndReward(ATH, 0, holders);
    }

    function test_end_cycle_not_step0_reverts() public {
        vm.prank(keeper);
        vault.advanceStep();

        address[] memory holders = new address[](0);
        vm.prank(keeper);
        vm.expectRevert("TPB: not at step 0");
        vault.endCycleAndReward(130_000e8, 0, holders);
    }

    function test_M1_too_many_holders_reverts() public {
        address[] memory holders = new address[](51);
        for (uint i = 0; i < 51; i++) holders[i] = address(uint160(i + 100));

        vm.prank(keeper);
        vm.expectRevert("TPB: too many holders");
        vault.endCycleAndReward(130_000e8, 0, holders);
    }

    // ================================================================
    // M4: Entry Protection Fees
    // ================================================================

    function test_M4_entry_fee_near_ath() public {
        // Set price to ATH - 1% (within tier2: 5% fee)
        vm.prank(keeper);
        vault.updatePrice(ATH * 99 / 100);

        uint256 feeBPS = vault.getEntryFeeBPS();
        assertEq(feeBPS, 500, "5% fee near ATH");

        // Set fee recipient
        vault.setFeeRecipient(address(0xFEE));

        // Deposit with fee
        wbtc.mint(alice, ONE_BTC);
        vm.startPrank(alice);
        wbtc.approve(address(vault), ONE_BTC);
        vault.deposit(ONE_BTC);
        vm.stopPrank();

        // Fee recipient should have received 5%
        assertEq(wbtc.balanceOf(address(0xFEE)), ONE_BTC * 5 / 100, "fee collected");
    }

    function test_M4_no_fee_far_from_ath() public {
        // Price at ATH - 10% (no fee)
        vm.prank(keeper);
        vault.updatePrice(ATH * 90 / 100);

        assertEq(vault.getEntryFeeBPS(), 0, "no fee far from ATH");
    }

    // ================================================================
    // H1: safeWBTC Rate Limiting
    // ================================================================

    function test_H1_safe_wbtc_rate_limited() public {
        // Initial deposit & rebalance
        _depositAs(alice, 10 * ONE_BTC);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();
        // safeWBTC = 10 BTC after rebalance

        // First, do a small update to set lastSafeWBTCUpdate to current time
        vm.prank(keeper);
        vault.updateSafeWBTC(10 * ONE_BTC); // same value, refreshes timestamp

        // Now try >20% change within same day — should revert
        vm.prank(keeper);
        vm.expectRevert("TPB: safeWBTC change too large, need owner");
        vault.updateSafeWBTC(0);

        // Small change (10%) should work
        vm.prank(keeper);
        vault.updateSafeWBTC(9 * ONE_BTC);

        // After 1 day, large change should work
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vault.updateSafeWBTC(0);
    }

    function test_H1_force_update_owner_only() public {
        _depositAs(alice, 10 * ONE_BTC);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        // Owner can force update anytime
        vault.forceUpdateSafeWBTC(0);
        assertEq(vault.safeWBTC(), 0);
    }

    // ================================================================
    // Admin
    // ================================================================

    function test_set_safe() public {
        vault.setSafe(address(0x1234));
        assertEq(vault.safe(), address(0x1234));
    }

    function test_set_keeper() public {
        vault.setKeeper(address(0x5678));
        vm.prank(address(0x5678));
        vault.advanceStep();
        assertEq(vault.currentStep(), 1);
    }

    function test_recover_token() public {
        MockWBTC otherToken = new MockWBTC();
        otherToken.mint(address(vault), 1000);
        vault.recoverToken(address(otherToken), 1000);
        assertEq(otherToken.balanceOf(address(this)), 1000);
    }

    function test_L3_recover_wbtc_reverts() public {
        vm.expectRevert("TPB: cannot recover WBTC");
        vault.recoverToken(address(wbtc), 1);
    }

    function test_admin_non_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: not owner");
        vault.setSafe(alice);
    }

    function test_transfer_ownership() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
        vm.prank(alice);
        vault.setSafe(bob);
        assertEq(vault.safe(), bob);
    }

    // ================================================================
    // Full Cycle Integration
    // ================================================================

    function test_full_cycle() public {
        // 1. Alice deposits 2 BTC, Bob deposits 1 BTC
        _depositAs(alice, 2 * ONE_BTC);
        _depositAs(bob, ONE_BTC);

        // 2. Rebalance
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        // 3. Price drops
        vm.prank(keeper);
        vault.advanceStep();
        vm.prank(keeper);
        vault.advanceStep();

        // 4. Lock
        vm.prank(keeper);
        vault.lockVault();

        // 5. Recovery — Safe returns WBTC + profit
        wbtc.mint(safe, 0.3e8);
        vm.prank(safe);
        wbtc.transfer(address(vault), 3.3e8);
        // Owner (test contract) force-updates safeWBTC
        vault.forceUpdateSafeWBTC(0);

        // 6. Unlock
        vm.prank(keeper);
        vault.unlockVault();

        // 7. Bob auto-redeem 100%
        vm.prank(bob);
        vault.setAutoRedeem(10000);

        // 8. End cycle (C2: auto-redeem first, then rewards)
        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, 0.15e8, holders);

        // Bob auto-redeemed → 0 TPB, got WBTC
        assertEq(vault.balanceOf(bob), 0, "bob auto-redeemed");
        assertTrue(wbtc.balanceOf(bob) > 0, "bob got WBTC");

        // Alice got rewards
        assertTrue(vault.balanceOf(alice) > 0, "alice has shares + reward");

        assertEq(vault.cycleNumber(), 2);
        assertEq(vault.currentATH(), 130_000e8);
    }

    // ================================================================
    // Helpers
    // ================================================================

    function _depositAs(address user, uint256 amount) internal {
        wbtc.mint(user, amount);
        vm.startPrank(user);
        wbtc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}
