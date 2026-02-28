// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NFTBonus.sol";

contract NFTBonusTest is Test {
    NFTBonus nft;
    address vault = address(0xAAAA);
    address safe = address(0x5AFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new NFTBonus(vault, safe, "https://btsave.io/nft/{id}.json");
    }

    // ===== Helpers =====
    function _mint(address user, uint256 cycle, uint8 tier) internal {
        vm.prank(vault);
        nft.mintCycleNFT(user, cycle, tier);
    }

    function _advanceCycle(uint256 cycle) internal {
        vm.prank(vault);
        nft.setCycle(cycle);
    }

    // ===== Minting =====
    function test_Mint_Basic() public {
        _mint(alice, 1, 1); // Bronze cycle 1
        assertEq(nft.balanceOf(11, alice), 1); // tokenId = 1*10+1 = 11
    }

    function test_Mint_OnlyVault() public {
        vm.prank(alice);
        vm.expectRevert("NFT: only vault");
        nft.mintCycleNFT(alice, 1, 1);
    }

    function test_Mint_InvalidTier() public {
        vm.prank(vault);
        vm.expectRevert("NFT: invalid tier");
        nft.mintCycleNFT(alice, 1, 0);

        vm.prank(vault);
        vm.expectRevert("NFT: invalid tier");
        nft.mintCycleNFT(alice, 1, 5);
    }

    // ===== Bonus: No NFTs =====
    function test_Bonus_NoNFTs() public view {
        assertEq(nft.getBonusMultiplier(alice), 10000); // 1.00×
    }

    // ===== Bonus: Single cycle Bronze =====
    function test_Bonus_SingleCycle_Bronze() public {
        _mint(alice, 1, 1); // Bronze
        _advanceCycle(2);   // Now in cycle 2, cycle 1 counts

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Base = 1 + 0.12×1 = 1.12 = 11200
        // Tier = Bronze = 10000
        // Completion = 1 cycle, 1 held = 1.35 = 13500
        // Total = 11200 * 10000 / 10000 * 13500 / 10000 = 15120
        assertEq(bonus, 15120);
    }

    // ===== Bonus: Single cycle Platinum =====
    function test_Bonus_SingleCycle_Platinum() public {
        _mint(alice, 1, 4); // Platinum
        _advanceCycle(2);

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Base = 11200, Tier = 17500, Completion = 13500
        // 11200 * 17500 / 10000 * 13500 / 10000 = 26460
        assertEq(bonus, 26460);
    }

    // ===== Bonus: 3 cycles all Gold, complete =====
    function test_Bonus_ThreeCycles_AllGold_Complete() public {
        _mint(alice, 1, 3); // Gold
        _mint(alice, 2, 3); // Gold
        _mint(alice, 3, 3); // Gold
        _advanceCycle(4);

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Base = 1 + 0.12×3 = 1.36 = 13600
        // Tier = Gold = 14500
        // Completion = 3/3 = 1.35 = 13500
        // 13600 * 14500 / 10000 * 13500 / 10000 = 26622
        assertEq(bonus, 26622);
    }

    // ===== Bonus: Mixed tiers (lowest = Silver) =====
    function test_Bonus_MixedTiers_LowestSilver() public {
        _mint(alice, 1, 4); // Platinum
        _mint(alice, 2, 2); // Silver (lowest)
        _mint(alice, 3, 3); // Gold
        _advanceCycle(4);

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Base = 1 + 0.12×3 = 1.36 = 13600
        // Tier = Silver (lowest) = 12000
        // Completion = 3/3 = 1.35 = 13500
        // 13600 * 12000 / 10000 * 13500 / 10000 = 22032
        assertEq(bonus, 22032);
    }

    // ===== Bonus: Incomplete collection =====
    function test_Bonus_Incomplete() public {
        _mint(alice, 1, 3); // Gold
        // Skip cycle 2
        _mint(alice, 3, 3); // Gold
        _advanceCycle(4);

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Base = 1 + 0.12×2 = 1.24 = 12400
        // Tier = Gold = 14500
        // Completion = 2/3 = NOT complete = 10000
        // 12400 * 14500 / 10000 * 10000 / 10000 = 17980
        assertEq(bonus, 17980);
    }

    // ===== Current cycle excluded (except cycle 1) =====
    function test_Bonus_CurrentCycleExcluded() public {
        _mint(alice, 1, 4); // Platinum cycle 1
        _mint(alice, 2, 4); // Platinum cycle 2 (current)
        _advanceCycle(2);   // We're in cycle 2

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Only cycle 1 counts (cycle 2 = current, excluded)
        // Base = 1 + 0.12×1 = 11200
        // Tier = Platinum = 17500
        // Completion = 1/1 = 13500
        // 11200 * 17500 / 10000 * 13500 / 10000 = 26460
        assertEq(bonus, 26460);
    }

    // ===== Cycle 1 exception: current cycle counts =====
    function test_Bonus_Cycle1_CurrentCounts() public {
        _mint(alice, 1, 3); // Gold cycle 1
        // Still in cycle 1 (excludeCycle = 0 because currentCycle == 1)

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Cycle 1 counts (exception for first cycle)
        // Base = 1 + 0.12×1 = 11200
        // Tier = Gold = 14500
        // Completion = 1/1 = 13500
        // 11200 * 14500 / 10000 * 13500 / 10000 = 21924
        assertEq(bonus, 21924);
    }

    // ===== Trading: sell NFT loses bonus =====
    function test_Trading_SellLosesBonus() public {
        _mint(alice, 1, 4); // Platinum
        _advanceCycle(2);

        assertEq(nft.getBonusMultiplier(alice), 26460);

        // Alice sells to Bob
        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 14, 1, "");

        // Alice lost bonus
        assertEq(nft.getBonusMultiplier(alice), 10000); // 1.00×
        // Bob gains bonus
        assertEq(nft.getBonusMultiplier(bob), 26460);
    }

    // ===== Best tier per cycle only =====
    function test_BestTierPerCycle() public {
        _mint(alice, 1, 1); // Bronze cycle 1
        _mint(alice, 1, 4); // Platinum cycle 1 (upgrade)
        _advanceCycle(2);

        uint256 bonus = nft.getBonusMultiplier(alice);
        // Best tier for cycle 1 = Platinum (scans from highest)
        // Base = 11200, Tier = Platinum = 17500, Completion = 13500
        assertEq(bonus, 26460);
    }

    // ===== Multiple duplicates same cycle don't help =====
    function test_DuplicatesSameCycle() public {
        _mint(alice, 1, 3); // Gold cycle 1
        _mint(alice, 1, 3); // Gold cycle 1 again
        _mint(alice, 1, 3); // Gold cycle 1 again
        _advanceCycle(2);

        // Still just 1 distinct cycle
        (uint256 distinct,,,,,,) = nft.getBonusBreakdown(alice);
        assertEq(distinct, 1);
    }

    // ===== Breakdown view =====
    function test_Breakdown() public {
        _mint(alice, 1, 2); // Silver
        _mint(alice, 2, 3); // Gold
        _advanceCycle(3);

        (uint256 distinct, uint8 lowest, bool complete, uint256 baseBps, uint256 tierBps, uint256 completionBps, uint256 total) = nft.getBonusBreakdown(alice);
        assertEq(distinct, 2);
        assertEq(lowest, 2); // Silver
        assertTrue(complete); // 2/2
        assertEq(baseBps, 12400); // 1 + 0.12×2
        assertEq(tierBps, 12000); // Silver
        assertEq(completionBps, 13500);
    }

    // ===== ERC-1155 transfer =====
    function test_Transfer() public {
        _mint(alice, 1, 1);
        assertEq(nft.balanceOf(11, alice), 1);

        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 11, 1, "");
        assertEq(nft.balanceOf(11, alice), 0);
        assertEq(nft.balanceOf(11, bob), 1);
    }

    function test_Transfer_Unauthorized() public {
        _mint(alice, 1, 1);

        vm.prank(bob);
        vm.expectRevert("NFT: not authorized");
        nft.safeTransferFrom(alice, bob, 11, 1, "");
    }

    function test_ApprovalForAll() public {
        _mint(alice, 1, 1);

        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vm.prank(bob);
        nft.safeTransferFrom(alice, bob, 11, 1, "");
        assertEq(nft.balanceOf(11, bob), 1);
    }
}
