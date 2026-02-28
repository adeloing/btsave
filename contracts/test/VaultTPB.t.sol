// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VaultTPB.sol";
import "../src/LimitedSignerModule.sol";

contract MockERC20 is IERC20 {
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

contract MockAavePoolV2 {
    uint256 public mockCollateral = 500_000e8;
    uint256 public mockDebt = 100_000e8;
    function setData(uint256 col, uint256 debt) external { mockCollateral = col; mockDebt = debt; }
    function getUserAccountData(address) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        return (mockCollateral, mockDebt, 0, 0, 0, 2e18);
    }
}

contract MockOracleV2 {
    int256 public price = 100_000e8;
    function setPrice(int256 p) external { price = p; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MockSafeV2 {
    function execTransactionFromModule(address, uint256, bytes calldata, uint8) external returns (bool) { return true; }
    function getOwners() external view returns (address[] memory) { return new address[](0); }
    function isOwner(address) external pure returns (bool) { return false; }
}

contract VaultTPBTest is Test {
    VaultTPB vault;
    MockERC20 usdc;
    MockERC20 wbtc;
    MockAavePoolV2 aavePool;
    MockOracleV2 oracle;
    MockSafeV2 safe;
    LimitedSignerModule lsm;

    address keeper = address(0x1111);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address treasury = address(0xFEE);

    uint256 constant ATH = 126_000e8; // $126,000 in 8 decimals

    function setUp() public {
        usdc = new MockERC20("USDC", 6);
        wbtc = new MockERC20("WBTC", 8);
        aavePool = new MockAavePoolV2();
        oracle = new MockOracleV2();
        safe = new MockSafeV2();

        lsm = new LimitedSignerModule(
            address(safe),
            address(aavePool),
            address(oracle)
        );

        // Setup keeper in LSM
        vm.prank(address(safe));
        lsm.setKeeper(keeper, true);

        oracle.setPrice(100_000e8); // $100,000

        vault = new VaultTPB(
            address(usdc),
            address(wbtc),
            address(aavePool),
            address(oracle),
            address(safe),
            address(lsm),
            treasury,
            ATH
        );

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 50_000e6);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ===== Deposit =====
    function test_Deposit_Basic() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.pendingPoolBalance(), 10_000e6);
    }

    function test_Deposit_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert("TPB: zero deposit");
        vault.deposit(0);
    }

    function test_Deposit_EntryFee_NearATH() public {
        // Price at ATH - 2% = $123,480 (in tier 1: 2% fee)
        oracle.setPrice(123_480e8);

        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        // 2% fee = 200 USDC
        assertEq(vault.treasuryAccrued(), 200e6);
        assertEq(vault.pendingPoolBalance(), 9_800e6);
    }

    function test_Deposit_EntryFee_AboveATH() public {
        oracle.setPrice(130_000e8); // Above ATH → 8% fee

        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        assertEq(vault.treasuryAccrued(), 800e6); // 8%
        assertEq(vault.pendingPoolBalance(), 9_200e6);
    }

    function test_Deposit_NoFee_BelowThreshold() public {
        oracle.setPrice(100_000e8); // Well below ATH - 3%

        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        assertEq(vault.treasuryAccrued(), 0);
        assertEq(vault.pendingPoolBalance(), 10_000e6);
    }

    // ===== Auto-Redeem =====
    function test_AutoRedeem_Set() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(alice);
        vault.setAutoRedeemAtNextATH(50);
        assertEq(vault.autoRedeemPct(alice), 50);
    }

    function test_AutoRedeem_MaxExceeded() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(alice);
        vm.expectRevert("TPB: max 100%");
        vault.setAutoRedeemAtNextATH(101);
    }

    function test_AutoRedeem_NoPosition() public {
        vm.prank(alice);
        vm.expectRevert("TPB: no position");
        vault.setAutoRedeemAtNextATH(50);
    }

    // ===== Time-Weighted Accounting =====
    function test_TimeWeighted_SingleUser() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.warp(2000); // 1000s later
        uint256 share = vault.getUserTimeWeightedShare(alice);
        assertEq(share, 10000); // 100% = 10000 BPS (only user)
    }

    function test_TimeWeighted_TwoUsers() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        uint256 aliceBal = vault.balanceOf(alice);

        vm.warp(2000); // Bob joins 1000s later
        vm.prank(bob);
        vault.deposit(10_000e6);

        uint256 bobBal = vault.balanceOf(bob);

        vm.warp(3000); // Check at t=3000

        uint256 aliceShare = vault.getUserTimeWeightedShare(alice);
        uint256 bobShare = vault.getUserTimeWeightedShare(bob);

        // Alice had aliceBal for 2000s, Bob had bobBal for 1000s
        // Note: bobBal << aliceBal because NAV changed (Bob's USDC buys fewer TPB)
        // Alice's share should dominate
        assertGt(aliceShare, bobShare);
        assertGt(aliceShare, 5000); // Alice > 50%

        // Verify shares sum to ~100%
        assertApproxEqAbs(aliceShare + bobShare, 10000, 10);
    }

    // ===== Pending Pool Rebalance =====
    function test_PendingPool_Rebalance_Weekly() public {
        // Set high collateral so 1000 USDC deposit is < 2% threshold
        aavePool.setData(5_000_000e8, 0); // $5M deployed

        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(1_000e6); // 1k vs 5M = 0.02% << 2%

        // Can't rebalance immediately (below threshold, before weekly)
        vm.prank(keeper);
        vm.expectRevert("TPB: conditions not met");
        vault.rebalancePendingPool();

        // After 7 days
        vm.warp(1000 + 7 days);
        vm.prank(keeper);
        vault.rebalancePendingPool();

        assertEq(vault.pendingPoolBalance(), 0);
    }

    function test_PendingPool_Rebalance_Threshold() public {
        // Set small total assets so deposit exceeds 2% threshold
        aavePool.setData(10_000e8, 0); // $10k collateral, no debt

        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6); // Deposit equals total assets → way over 2%

        vm.prank(keeper);
        vault.rebalancePendingPool();
        assertEq(vault.pendingPoolBalance(), 0);
    }

    // ===== Unwind =====
    function test_Unwind_Propose() public {
        oracle.setPrice(int256(ATH)); // At ATH

        vm.prank(keeper);
        vault.proposeUnwind();

        assertTrue(vault.unwindPending());
        assertTrue(vault.redemptionWindowOpen());
    }

    function test_Unwind_NotAtATH() public {
        oracle.setPrice(100_000e8); // Below ATH

        vm.prank(keeper);
        vm.expectRevert("TPB: not at ATH");
        vault.proposeUnwind();
    }

    function test_Unwind_HumanExecution() public {
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();

        vm.prank(address(safe));
        vault.executeUnwind();

        assertFalse(vault.unwindPending());
        assertFalse(vault.cycleActive());
    }

    function test_Unwind_AutoExecution_AfterTimelock() public {
        oracle.setPrice(int256(ATH));
        vm.warp(1000);
        vm.prank(keeper);
        vault.proposeUnwind();

        // Before timelock — should fail
        vm.warp(1000 + 24 minutes);
        vm.expectRevert("TPB: timelock not expired");
        vault.autoExecuteUnwind();

        // After timelock
        vm.warp(1000 + 26 minutes);
        vault.autoExecuteUnwind();

        assertFalse(vault.unwindPending());
        assertFalse(vault.cycleActive());
    }

    // ===== Auto-Lock =====
    function test_AutoLock() public {
        // First, open redemption window via unwind proposal
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();
        assertTrue(vault.redemptionWindowOpen());

        // Price drops below ATH - 5%
        oracle.setPrice(int256(ATH * 9400 / 10000)); // ATH - 6%

        vm.prank(keeper);
        vault.autoLock();
        assertFalse(vault.redemptionWindowOpen());
    }

    // ===== Cycle Management =====
    function test_NewCycle() public {
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();
        vm.prank(address(safe));
        vault.executeUnwind();

        // Start new cycle
        uint256 newATH = 150_000e8;
        vm.prank(address(safe));
        vault.startNewCycle(newATH);

        assertEq(vault.currentCycle(), 2);
        assertEq(vault.cycleATH(), newATH);
        assertTrue(vault.cycleActive());
    }

    // ===== View Functions =====
    function test_GetCycleInfo() public view {
        (uint256 cycle, uint256 ath, uint256 start, bool active, bool redemption, bool unwind) = vault.getCycleInfo();
        assertEq(cycle, 1);
        assertEq(ath, ATH);
        assertTrue(active);
        assertFalse(redemption);
        assertFalse(unwind);
    }

    function test_GetUserInfo() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(alice);
        vault.setAutoRedeemAtNextATH(25);

        vm.warp(2000);
        (uint256 balance, uint256 redeem, uint256 share, uint256 usdcValue) = vault.getUserInfo(alice);
        assertGt(balance, 0);
        assertEq(redeem, 25);
        assertEq(share, 10000); // 100% sole user
        assertGt(usdcValue, 0);
    }

    // ===== Transfer updates checkpoints =====
    function test_Transfer_UpdatesCheckpoints() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.warp(2000);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.transfer(bob, half);

        vm.warp(3000);
        uint256 aliceShare = vault.getUserTimeWeightedShare(alice);
        uint256 bobShare = vault.getUserTimeWeightedShare(bob);

        // Alice had 100% for 1000s, then 50% for 1000s = 1500 units
        // Bob had 0% for 1000s, then 50% for 1000s = 500 units
        // Total = 2000. Alice = 75%, Bob = 25%
        assertApproxEqAbs(aliceShare, 7500, 10);
        assertApproxEqAbs(bobShare, 2500, 10);
    }

    // ===== Auto-Redeem Pro-Rata =====
    function test_AutoRedeem_FullLiquidity() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(alice);
        vault.setAutoRedeemAtNextATH(50);

        // Fund vault with WBTC for redemption
        wbtc.mint(address(vault), 10e8); // 10 BTC

        // Trigger unwind
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();
        vm.prank(address(safe));
        vault.executeUnwind();

        // Alice should have received WBTC
        assertGt(wbtc.balanceOf(alice), 0);
        // Auto-redeem pct should be reset
        assertEq(vault.autoRedeemPct(alice), 0);
    }

    function test_AutoRedeem_ProRata() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(50_000e6);
        vm.prank(bob);
        vault.deposit(50_000e6);

        vm.prank(alice);
        vault.setAutoRedeemAtNextATH(100);
        vm.prank(bob);
        vault.setAutoRedeemAtNextATH(100);

        // Fund vault with only 0.1 BTC (less than total demand)
        wbtc.mint(address(vault), 0.1e8);

        // Check stats
        (uint256 users,) = vault.getAutoRedeemStats();
        assertEq(users, 2);

        // Trigger unwind
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();
        vm.prank(address(safe));
        vault.executeUnwind();

        // Both should have received WBTC (pro-rata)
        uint256 aliceWBTC = wbtc.balanceOf(alice);
        uint256 bobWBTC = wbtc.balanceOf(bob);
        assertGt(aliceWBTC, 0);
        assertGt(bobWBTC, 0);
        // Total distributed should equal available
        assertApproxEqAbs(aliceWBTC + bobWBTC, 0.1e8, 1);
    }

    function test_AutoRedeem_NoWBTC() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(alice);
        vault.setAutoRedeemAtNextATH(100);

        // No WBTC in vault — unwind should still work
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();
        vm.prank(address(safe));
        vault.executeUnwind();

        assertEq(wbtc.balanceOf(alice), 0);
        assertFalse(vault.cycleActive());
    }

    // ===== NFT Eligibility (balance_end >= balance_start) =====
    function test_NFTEligible_DepositOnly() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        // Alice deposited, balance grew from 0 → eligible
        assertTrue(vault.isNFTEligible(alice));
    }

    function test_NFTEligible_AfterTransferOut() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        uint256 bal = vault.balanceOf(alice);

        // Transfer half out → balance decreased
        vm.prank(alice);
        vault.transfer(bob, bal / 2);

        assertFalse(vault.isNFTEligible(alice));
        // Bob received mid-cycle with 0 start → eligible
        assertTrue(vault.isNFTEligible(bob));
    }

    function test_NFTEligible_DepositMore() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        // Deposit more → balance increased → still eligible
        vm.warp(2000);
        vm.prank(alice);
        vault.deposit(5_000e6);

        assertTrue(vault.isNFTEligible(alice));
    }

    function test_NFTEligible_NewCycleResets() public {
        vm.warp(1000);
        vm.prank(alice);
        vault.deposit(10_000e6);

        uint256 bal = vault.balanceOf(alice);

        // Transfer out → ineligible
        vm.prank(alice);
        vault.transfer(bob, bal / 2);
        assertFalse(vault.isNFTEligible(alice));

        // End cycle and start new one
        oracle.setPrice(int256(ATH));
        vm.prank(keeper);
        vault.proposeUnwind();
        vm.prank(address(safe));
        vault.executeUnwind();
        vm.prank(address(safe));
        vault.startNewCycle(150_000e8);

        // New cycle: Alice's current balance becomes new start → eligible again
        // (lazy snapshot not yet taken, so start = current)
        assertTrue(vault.isNFTEligible(alice));
    }

    // ===== Entry Fee View =====
    function test_GetEntryFeeBps() public {
        oracle.setPrice(100_000e8); // Well below ATH-3%
        assertEq(vault.getEntryFeeBps(), 0);

        oracle.setPrice(123_000e8); // ATH-3% to ATH-1.5% range
        assertEq(vault.getEntryFeeBps(), 200);

        oracle.setPrice(125_000e8); // ATH-1.5% to ATH
        assertEq(vault.getEntryFeeBps(), 500);

        oracle.setPrice(130_000e8); // Above ATH
        assertEq(vault.getEntryFeeBps(), 800);
    }
}
