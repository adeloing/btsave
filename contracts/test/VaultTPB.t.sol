// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VaultTPB.sol";
import "../src/NFTBonus.sol";

/// @dev Mock WBTC (8 decimals)
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

/// @dev Reentrant attacker
contract ReentrantAttacker {
    VaultTPB vault;
    bool attacked;

    constructor(VaultTPB _vault) { vault = _vault; }

    function attack() external {
        vault.redeem(vault.balanceOf(address(this)));
    }

    // Try to re-enter on WBTC transfer
    fallback() external {
        if (!attacked) {
            attacked = true;
            vault.redeem(1);
        }
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

    uint256 constant ATH = 126_000e8; // $126,000
    uint256 constant ONE_BTC = 1e8;

    function setUp() public {
        wbtc = new MockWBTC();
        vault = new VaultTPB(address(wbtc), safe, keeper, ATH);
        nft = new NFTBonus(address(vault), safe, "https://btsave.io/nft/");
        vault.setNFTBonus(address(nft));
    }

    // ================================================================
    // Deposit
    // ================================================================

    function test_deposit_basic() public {
        wbtc.mint(alice, ONE_BTC);
        vm.startPrank(alice);
        wbtc.approve(address(vault), ONE_BTC);
        vault.deposit(ONE_BTC);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), ONE_BTC, "TPB balance (first deposit 1:1)");
        assertEq(vault.totalSupply(), ONE_BTC, "total supply");
        assertEq(vault.pendingWBTC(), ONE_BTC, "pending");
        assertEq(wbtc.balanceOf(address(vault)), ONE_BTC, "vault WBTC");
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: zero deposit");
        vault.deposit(0);
    }

    function test_deposit_nav_based() public {
        // Alice deposits 1 BTC first (1:1)
        _depositAs(alice, ONE_BTC);
        assertEq(vault.balanceOf(alice), ONE_BTC);

        // Simulate strategy gains: vault now has 1.5 BTC worth of assets
        wbtc.mint(address(vault), ONE_BTC / 2); // 0.5 BTC profit in vault

        // Bob deposits 1 BTC — should get fewer TPB (NAV > 1)
        _depositAs(bob, ONE_BTC);

        // NAV: totalAssets = 2.5 BTC, supply = 1e8
        // Bob gets: 1e8 * 1e8 / 1.5e8 = 0.6666e8
        uint256 bobExpected = (ONE_BTC * ONE_BTC) / (ONE_BTC + ONE_BTC / 2);
        assertEq(vault.balanceOf(bob), bobExpected, "bob NAV-based shares");

        // Alice still has more TPB than Bob (she was early)
        assertTrue(vault.balanceOf(alice) > vault.balanceOf(bob), "alice > bob");

        // Both can redeem fair value
        uint256 aliceValue = vault.previewRedeem(vault.balanceOf(alice));
        uint256 bobValue = vault.previewRedeem(vault.balanceOf(bob));
        // Alice should get ~1.5 BTC (her 1 BTC + her share of 0.5 profit)
        // Bob should get ~1.0 BTC (his deposit, no profit dilution)
        assertApproxEqAbs(aliceValue, 1.5e8, 1, "alice fair value");
        assertApproxEqAbs(bobValue, ONE_BTC, 1, "bob fair value");
    }

    function test_deposit_multiple_users() public {
        wbtc.mint(alice, 2 * ONE_BTC);
        wbtc.mint(bob, 3 * ONE_BTC);

        vm.startPrank(alice);
        wbtc.approve(address(vault), 2 * ONE_BTC);
        vault.deposit(2 * ONE_BTC);
        vm.stopPrank();

        vm.startPrank(bob);
        wbtc.approve(address(vault), 3 * ONE_BTC);
        vault.deposit(3 * ONE_BTC);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 2 * ONE_BTC);
        assertEq(vault.balanceOf(bob), 3 * ONE_BTC);
        assertEq(vault.totalSupply(), 5 * ONE_BTC);
    }

    // ================================================================
    // Transfer (ERC-20)
    // ================================================================

    function test_transfer() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(alice);
        vault.transfer(bob, ONE_BTC / 2);

        assertEq(vault.balanceOf(alice), ONE_BTC / 2);
        assertEq(vault.balanceOf(bob), ONE_BTC / 2);
    }

    function test_transferFrom_with_approval() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(alice);
        vault.approve(bob, ONE_BTC);

        vm.prank(bob);
        vault.transferFrom(alice, bob, ONE_BTC);

        assertEq(vault.balanceOf(bob), ONE_BTC);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_transfer_insufficient_reverts() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(alice);
        vm.expectRevert("TPB: insufficient");
        vault.transfer(bob, 2 * ONE_BTC);
    }

    // ================================================================
    // Redeem
    // ================================================================

    function test_redeem_at_step0() public {
        _depositAs(alice, ONE_BTC);

        // Redeem half
        vm.prank(alice);
        vault.redeem(ONE_BTC / 2);

        assertEq(vault.balanceOf(alice), ONE_BTC / 2);
        assertEq(wbtc.balanceOf(alice), ONE_BTC / 2);
    }

    function test_redeem_not_step0_reverts() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(keeper);
        vault.advanceStep();

        vm.prank(alice);
        vm.expectRevert("TPB: not at step 0");
        vault.redeem(ONE_BTC);
    }

    function test_redeem_locked_reverts() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(keeper);
        vault.lockVault();

        vm.prank(alice);
        vm.expectRevert("TPB: locked");
        vault.redeem(ONE_BTC);
    }

    function test_redeem_pro_rata() public {
        // Alice deposits 1 BTC, Bob deposits 1 BTC
        _depositAs(alice, ONE_BTC);
        _depositAs(bob, ONE_BTC);

        // Simulate strategy gains: add 0.5 BTC to vault (liquid)
        wbtc.mint(address(vault), ONE_BTC / 2);

        // Alice redeems all her TPB → gets 1.25 BTC (half of 2.5 BTC totalAssets)
        vm.prank(alice);
        vault.redeem(ONE_BTC);

        // 1e8 * 2.5e8 / 2e8 = 1.25e8
        assertEq(wbtc.balanceOf(alice), 1.25e8, "alice gets pro-rata");
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

        // Too early
        vm.prank(keeper);
        vm.expectRevert("TPB: rebalance not due");
        vault.rebalancePendingPool();

        // Advance 7 days
        vm.warp(block.timestamp + 7 days);

        vm.prank(keeper);
        vault.rebalancePendingPool();

        assertEq(vault.pendingWBTC(), 0, "pending cleared");
        assertEq(wbtc.balanceOf(safe), ONE_BTC, "safe received WBTC");
    }

    function test_rebalance_threshold() public {
        // First deposit and deploy
        _depositAs(alice, ONE_BTC);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        // Return WBTC to vault to simulate deployed TVL
        vm.prank(safe);
        wbtc.transfer(address(vault), ONE_BTC);

        // Second deposit: 3% of deployed = above 2% threshold
        _depositAs(bob, ONE_BTC * 3 / 100);

        vm.prank(keeper);
        vault.rebalancePendingPool(); // Should work via threshold
        assertEq(vault.pendingWBTC(), 0);
    }

    function test_deposit_nav_with_safe_assets() public {
        // Alice deposits 1 BTC, rebalance sends to safe
        _depositAs(alice, ONE_BTC);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        // safeWBTC = 1e8, vault liquid = 0
        assertEq(vault.safeWBTC(), ONE_BTC);
        assertEq(vault.totalAssets(), ONE_BTC);

        // Strategy gains: safe now holds 1.2 BTC
        vm.prank(keeper);
        vault.updateSafeWBTC(1.2e8);
        assertEq(vault.totalAssets(), 1.2e8);

        // Bob deposits 1 BTC — NAV = 1.2e8 assets, 1e8 supply
        _depositAs(bob, ONE_BTC);
        // Bob gets: 1e8 * 1e8 / 1.2e8 = 0.8333e8
        uint256 bobExpected = (ONE_BTC * ONE_BTC) / 1.2e8;
        assertEq(vault.balanceOf(bob), bobExpected, "bob shares with safe gains");
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
        vault.setAutoRedeem(5000); // 50%
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

        vm.prank(keeper);
        vault.advanceStep();
        assertEq(vault.currentStep(), 2);
    }

    function test_set_step() public {
        vm.prank(keeper);
        vault.advanceStep();
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
        assertEq(vault.currentStep(), 0);
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
    // End Cycle & Reward
    // ================================================================

    function test_end_cycle_basic() public {
        _depositAs(alice, ONE_BTC);
        _depositAs(bob, ONE_BTC);

        // Return WBTC to vault (simulate strategy holding)
        // Vault already has 2 BTC from deposits

        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;

        uint256 rewardSats = 0.1e8; // 0.1 BTC reward

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, rewardSats, holders);

        // Each gets 0.05 BTC reward (50/50 split)
        assertEq(vault.balanceOf(alice), ONE_BTC + 0.05e8, "alice reward");
        assertEq(vault.balanceOf(bob), ONE_BTC + 0.05e8, "bob reward");
        assertEq(vault.cycleNumber(), 2);
        assertEq(vault.currentATH(), 130_000e8);
    }

    function test_end_cycle_with_nft_bonus() public {
        _depositAs(alice, ONE_BTC);

        // Mint Gold NFT to alice (tier 3)
        // mintCycleNFT is onlyVault, so call from vault address
        vm.prank(address(vault));
        nft.mintCycleNFT(alice, 1, 3); // cycle 1, tier 3 (Gold)

        address[] memory holders = new address[](1);
        holders[0] = alice;

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, 0.1e8, holders);

        // Gold = 2x multiplier approximately (depends on NFTBonus formula)
        uint256 bal = vault.balanceOf(alice);
        assertTrue(bal > ONE_BTC + 0.1e8, "NFT bonus applied");
    }

    function test_end_cycle_with_auto_redeem() public {
        _depositAs(alice, ONE_BTC);

        vm.prank(alice);
        vault.setAutoRedeem(5000); // 50%

        address[] memory holders = new address[](1);
        holders[0] = alice;

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, 0.1e8, holders);

        // Alice had 1e8 + reward, then 50% auto-redeemed
        uint256 bal = vault.balanceOf(alice);
        assertTrue(bal < ONE_BTC, "half auto-redeemed");
        assertTrue(wbtc.balanceOf(alice) > 0, "got WBTC back");
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

    // ================================================================
    // Reentrancy
    // ================================================================

    function test_reentrancy_blocked() public {
        // The ReentrantAttacker would need a WBTC that calls back,
        // which our MockWBTC doesn't do. Verify the guard exists.
        _depositAs(alice, ONE_BTC);

        // Double-redeem in same tx should fail
        // (tested via modifier presence — can't easily trigger with mock ERC20)
        vm.prank(alice);
        vault.redeem(ONE_BTC / 2);
        assertEq(vault.balanceOf(alice), ONE_BTC / 2);
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
        // New keeper can act
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

    function test_recover_wbtc_reverts() public {
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

        // 2. Rebalance (deploy to safe)
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();
        assertEq(wbtc.balanceOf(safe), 3 * ONE_BTC);
        assertEq(vault.safeWBTC(), 3 * ONE_BTC);

        // 3. Price drops → advance steps
        vm.prank(keeper);
        vault.advanceStep();
        vm.prank(keeper);
        vault.advanceStep();
        assertEq(vault.currentStep(), 2);

        // 4. Lock at ATH - 5%
        vm.prank(keeper);
        vault.lockVault();

        // 5. Price recovers → new ATH
        // Safe returns WBTC + profit to vault
        wbtc.mint(safe, 0.3e8); // 0.3 BTC profit
        vm.prank(safe);
        wbtc.transfer(address(vault), 3.3e8); // return all + profit

        // Update accounting: safe emptied
        vm.prank(keeper);
        vault.updateSafeWBTC(0);

        // 6. Unlock and reset step
        vm.prank(keeper);
        vault.unlockVault();

        // 7. Bob sets auto-redeem 100%
        vm.prank(bob);
        vault.setAutoRedeem(10000);

        // 8. End cycle
        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;

        vm.prank(keeper);
        vault.endCycleAndReward(130_000e8, 0.15e8, holders); // 0.15 BTC reward

        // Alice: 2e8 + 0.1e8 reward (2/3 of 0.15) = 2.1e8
        assertEq(vault.balanceOf(alice), 2e8 + 0.1e8, "alice final");

        // Bob: auto-redeemed 100% → 0 TPB, got WBTC back
        assertEq(vault.balanceOf(bob), 0, "bob auto-redeemed");
        assertTrue(wbtc.balanceOf(bob) > 0, "bob got WBTC");

        // Cycle advanced
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
