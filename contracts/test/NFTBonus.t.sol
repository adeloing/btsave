// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NFTBonus.sol";

contract NFTBonusTest is Test {
    NFTBonus nft;

    address vaultAddr = address(0x1);
    address admin = address(0xA);
    address alice = address(0x2);
    address bob = address(0x3);

    function setUp() public {
        nft = new NFTBonus(vaultAddr, admin, "https://example.com/{id}");
    }

    // ==================== MINTING ====================

    function test_mintCycleNFT() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1); // bronze

        uint256 tokenId = 1 * 10 + 1; // cycle*10 + tier
        assertEq(nft.balanceOf(tokenId, alice), 1);
    }

    function test_mintCycleNFT_allTiers() public {
        for (uint8 t = 1; t <= 4; t++) {
            vm.prank(vaultAddr);
            nft.mintCycleNFT(alice, 1, t);
            assertEq(nft.balanceOf(1 * 10 + t, alice), 1);
        }
    }

    function test_mintCycleNFT_invalidTier() public {
        vm.prank(vaultAddr);
        vm.expectRevert("NFT: invalid tier");
        nft.mintCycleNFT(alice, 1, 0);

        vm.prank(vaultAddr);
        vm.expectRevert("NFT: invalid tier");
        nft.mintCycleNFT(alice, 1, 5);
    }

    function test_mintCycleNFT_onlyVault() public {
        vm.prank(alice);
        vm.expectRevert("NFT: only vault");
        nft.mintCycleNFT(alice, 1, 1);
    }

    function test_mintCycleNFT_updatesHistoricalCycles() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 5, 1);
        assertEq(nft.totalHistoricalCycles(), 5);
    }

    // ==================== BONUS MULTIPLIER ====================

    function test_getBonusMultiplier_noNFTs() public {
        uint256 mult = nft.getBonusMultiplier(alice);
        assertEq(mult, 10000, "no NFTs = base 1x");
    }

    function test_getBonusMultiplier_oneBronze() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1); // bronze cycle 1

        vm.prank(vaultAddr);
        nft.setCycle(2); // so cycle 1 is not excluded

        uint256 mult = nft.getBonusMultiplier(alice);
        // base = 10000 + 1200*1 = 11200
        // tier = bronze = 10000
        // completion = 1 eligible, 1 held → 13500
        // total = 11200 * 10000 / 10000 * 13500 / 10000 = 15120
        assertEq(mult, 15120);
    }

    function test_getBonusMultiplier_onePlatinum() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 4); // platinum

        vm.prank(vaultAddr);
        nft.setCycle(2);

        uint256 mult = nft.getBonusMultiplier(alice);
        // base = 11200, tier = 17500, completion = 13500
        // 11200 * 17500 / 10000 * 13500 / 10000 = 26460
        assertEq(mult, 26460);
    }

    function test_getBonusMultiplier_multipleCycles() public {
        // 3 cycles with gold NFTs
        for (uint256 c = 1; c <= 3; c++) {
            vm.prank(vaultAddr);
            nft.mintCycleNFT(alice, c, 3); // gold
        }

        vm.prank(vaultAddr);
        nft.setCycle(4);

        uint256 mult = nft.getBonusMultiplier(alice);
        // base = 10000 + 1200*3 = 13600
        // tier = gold = 14500
        // completion = all 3 eligible cycles held → 13500
        // 13600 * 14500 / 10000 * 13500 / 10000 = 26622
        assertEq(mult, 26622);
    }

    function test_getBonusMultiplier_incompleteCollection() public {
        // 3 historical cycles, alice only has cycle 1 and 3
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 4);
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 3, 4);
        // cycle 2 has no NFT for alice, but needs to be registered
        vm.prank(vaultAddr);
        nft.mintCycleNFT(bob, 2, 1); // bob has cycle 2

        vm.prank(vaultAddr);
        nft.setCycle(4);

        uint256 mult = nft.getBonusMultiplier(alice);
        // base = 10000 + 1200*2 = 12400 (2 distinct cycles)
        // tier = platinum = 17500
        // completion = 3 eligible, 2 held → NOT complete → 10000
        // 12400 * 17500 / 10000 * 10000 / 10000 = 21700
        assertEq(mult, 21700);
    }

    // ==================== BONUS BREAKDOWN ====================

    function test_getBonusBreakdown() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 2); // silver

        vm.prank(vaultAddr);
        nft.setCycle(2);

        (uint256 distinctCycles, uint8 lowestTier, bool isComplete,
         uint256 baseBps, uint256 tierBps, uint256 completionBps, uint256 totalMult) = nft.getBonusBreakdown(alice);

        assertEq(distinctCycles, 1);
        assertEq(lowestTier, 2); // silver
        assertTrue(isComplete);
        assertEq(baseBps, 11200);
        assertEq(tierBps, 12000);
        assertEq(completionBps, 13500);
        assertEq(totalMult, 18144);
    }

    // ==================== TRANSFERS ====================

    function test_safeTransferFrom() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1);

        uint256 tokenId = 11;

        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, tokenId, 1, "");

        assertEq(nft.balanceOf(tokenId, alice), 0);
        assertEq(nft.balanceOf(tokenId, bob), 1);
    }

    function test_safeTransferFrom_notAuthorized() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1);

        vm.prank(bob);
        vm.expectRevert("NFT: not authorized");
        nft.safeTransferFrom(alice, bob, 11, 1, "");
    }

    function test_safeTransferFrom_withApproval() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1);

        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vm.prank(bob);
        nft.safeTransferFrom(alice, bob, 11, 1, "");

        assertEq(nft.balanceOf(11, bob), 1);
    }

    function test_safeTransferFrom_toZero() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1);

        vm.prank(alice);
        vm.expectRevert("NFT: transfer to zero");
        nft.safeTransferFrom(alice, address(0), 11, 1, "");
    }

    function test_safeBatchTransferFrom() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1);
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 11; ids[1] = 12;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1; amounts[1] = 1;

        vm.prank(alice);
        nft.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        assertEq(nft.balanceOf(11, bob), 1);
        assertEq(nft.balanceOf(12, bob), 1);
    }

    // ==================== BALANCE OF BATCH ====================

    function test_balanceOfBatch() public {
        vm.prank(vaultAddr);
        nft.mintCycleNFT(alice, 1, 1);
        vm.prank(vaultAddr);
        nft.mintCycleNFT(bob, 1, 2);

        address[] memory accounts = new address[](2);
        accounts[0] = alice; accounts[1] = bob;
        uint256[] memory ids = new uint256[](2);
        ids[0] = 11; ids[1] = 12;

        uint256[] memory bals = nft.balanceOfBatch(accounts, ids);
        assertEq(bals[0], 1);
        assertEq(bals[1], 1);
    }

    // ==================== ADMIN ====================

    function test_setURI() public {
        vm.prank(admin);
        nft.setURI("https://new.com/{id}");
        assertEq(nft.uri(), "https://new.com/{id}");
    }

    function test_setURI_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NFT: only admin");
        nft.setURI("x");
    }

    function test_setVault() public {
        vm.prank(admin);
        nft.setVault(address(0x999));
        assertEq(nft.vault(), address(0x999));
    }

    function test_setVault_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NFT: only admin");
        nft.setVault(address(0x999));
    }

    function test_setAdmin() public {
        vm.prank(admin);
        nft.setAdmin(alice);
        assertEq(nft.admin(), alice);
    }

    function test_setAdmin_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("NFT: zero admin");
        nft.setAdmin(address(0));
    }

    function test_setAdmin_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NFT: only admin");
        nft.setAdmin(alice);
    }

    // ==================== MAX SCAN CYCLES ====================

    function test_maxScanCycles_cap() public {
        // Mint NFTs for 110 cycles
        for (uint256 c = 1; c <= 110; c++) {
            vm.prank(vaultAddr);
            nft.mintCycleNFT(alice, c, 1);
        }

        vm.prank(vaultAddr);
        nft.setCycle(111);

        // Should not revert despite > 100 cycles
        uint256 mult = nft.getBonusMultiplier(alice);
        assertTrue(mult > 10000, "should have bonus");

        // Only scans last 100 cycles (11-110), not 1-10
        // So distinctCycles = 100 (all have NFTs)
        (uint256 distinctCycles,,,,,, ) = nft.getBonusBreakdown(alice);
        assertEq(distinctCycles, 100);
    }

    // ==================== ERC165 ====================

    function test_supportsInterface() public {
        assertTrue(nft.supportsInterface(0xd9b67a26)); // ERC-1155
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(nft.supportsInterface(0xdeadbeef));
    }

    // ==================== SET CYCLE ====================

    function test_setCycle_onlyVault() public {
        vm.prank(alice);
        vm.expectRevert("NFT: only vault");
        nft.setCycle(5);

        vm.prank(vaultAddr);
        nft.setCycle(5);
        assertEq(nft.currentCycle(), 5);
    }
}
