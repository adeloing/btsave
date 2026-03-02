// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NFTBonus — BTSAVE Cycle NFT Collection (ERC-1155)
 * @notice Mints 1 NFT per cycle per eligible user. 4 tiers: Bronze, Silver, Gold, Platinum.
 *
 * Audit fixes applied:
 *   M2 — Gas optimization: capped cycle scan to MAX_SCAN_CYCLES
 *   M3 — ERC-1155 compliance: onERC1155Received check + balanceOfBatch
 *
 * Token ID encoding: cycleNumber * 10 + tier
 *   tier: 1=Bronze, 2=Silver, 3=Gold, 4=Platinum
 *
 * Bonus Formula:
 *   BonusMultiplier = Base × TierQuality × Completion
 *   - Base = 1 + 0.12 × C  (C = distinct cycles in collection)
 *   - TierQuality: 1.00 (Bronze), 1.20 (Silver+), 1.45 (Gold+), 1.75 (Platinum)
 *   - Completion: 1.35 if user holds NFT for every historical cycle, else 1.00
 */

interface IERC1155Receiver {
    function onERC1155Received(
        address operator, address from, uint256 id, uint256 value, bytes calldata data
    ) external returns (bytes4);
    function onERC1155BatchReceived(
        address operator, address from, uint256[] calldata ids, uint256[] calldata values, bytes calldata data
    ) external returns (bytes4);
}

contract NFTBonus {
    // ============================================================
    //                        CONSTANTS
    // ============================================================

    uint8 public constant TIER_BRONZE = 1;
    uint8 public constant TIER_SILVER = 2;
    uint8 public constant TIER_GOLD = 3;
    uint8 public constant TIER_PLATINUM = 4;

    uint256 public constant BASE_PER_CYCLE_BPS = 1200;
    uint256 public constant TIER_BRONZE_BPS = 10000;
    uint256 public constant TIER_SILVER_BPS = 12000;
    uint256 public constant TIER_GOLD_BPS = 14500;
    uint256 public constant TIER_PLATINUM_BPS = 17500;
    uint256 public constant COMPLETION_BONUS_BPS = 13500;
    uint256 public constant BPS = 10000;

    // M2 fix: cap scan to prevent gas bombs
    uint256 public constant MAX_SCAN_CYCLES = 100;

    // ============================================================
    //                        STATE
    // ============================================================

    address public vault;
    address public safe;
    uint256 public currentCycle;

    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    uint256 public totalHistoricalCycles;

    string public uri;

    // ============================================================
    //                        EVENTS
    // ============================================================

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);
    event NFTMinted(address indexed user, uint256 indexed cycle, uint8 tier, uint256 tokenId);

    // ============================================================
    //                       MODIFIERS
    // ============================================================

    modifier onlyVault() {
        require(msg.sender == vault, "NFT: only vault");
        _;
    }

    modifier onlySafe() {
        require(msg.sender == safe, "NFT: only safe");
        _;
    }

    // ============================================================
    //                      CONSTRUCTOR
    // ============================================================

    constructor(address _vault, address _safe, string memory _uri) {
        vault = _vault;
        safe = _safe;
        uri = _uri;
        currentCycle = 1;
    }

    // ============================================================
    //                    MINTING (by Vault)
    // ============================================================

    function mintCycleNFT(address user, uint256 cycle, uint8 tier) external onlyVault {
        require(tier >= TIER_BRONZE && tier <= TIER_PLATINUM, "NFT: invalid tier");

        uint256 tokenId = cycle * 10 + tier;
        balanceOf[tokenId][user] += 1;

        if (cycle >= totalHistoricalCycles) {
            totalHistoricalCycles = cycle;
        }

        emit TransferSingle(msg.sender, address(0), user, tokenId, 1);
        emit NFTMinted(user, cycle, tier, tokenId);
    }

    function setCycle(uint256 newCycle) external onlyVault {
        currentCycle = newCycle;
    }

    // ============================================================
    //                    BONUS CALCULATION
    // ============================================================

    function getBonusMultiplier(address user) external view returns (uint256 multiplierBps) {
        if (totalHistoricalCycles == 0) return BPS;

        uint256 excludeCycle = currentCycle > 1 ? currentCycle : 0;

        // M2 fix: cap scan range
        uint256 scanFrom = totalHistoricalCycles > MAX_SCAN_CYCLES
            ? totalHistoricalCycles - MAX_SCAN_CYCLES + 1
            : 1;

        uint256 distinctCycles = 0;
        uint8 minTier = TIER_PLATINUM;
        bool hasAnyNFT = false;
        uint256 cyclesWithNFT = 0;
        uint256 totalEligible = 0;

        for (uint256 c = scanFrom; c <= totalHistoricalCycles; c++) {
            if (c == excludeCycle) continue;
            totalEligible++;

            uint8 bestTier = 0;
            for (uint8 t = TIER_PLATINUM; t >= TIER_BRONZE; t--) {
                if (balanceOf[c * 10 + t][user] > 0) {
                    bestTier = t;
                    break;
                }
            }

            if (bestTier > 0) {
                distinctCycles++;
                cyclesWithNFT++;
                hasAnyNFT = true;
                if (bestTier < minTier) minTier = bestTier;
            }
        }

        if (!hasAnyNFT) return BPS;

        uint256 baseBps = BPS + (BASE_PER_CYCLE_BPS * distinctCycles);

        uint256 tierBps;
        if (minTier == TIER_PLATINUM) tierBps = TIER_PLATINUM_BPS;
        else if (minTier == TIER_GOLD) tierBps = TIER_GOLD_BPS;
        else if (minTier == TIER_SILVER) tierBps = TIER_SILVER_BPS;
        else tierBps = TIER_BRONZE_BPS;

        uint256 completionBps;
        if (totalEligible > 0 && cyclesWithNFT >= totalEligible) {
            completionBps = COMPLETION_BONUS_BPS;
        } else {
            completionBps = BPS;
        }

        multiplierBps = baseBps * tierBps / BPS * completionBps / BPS;
    }

    function getBonusBreakdown(address user) external view returns (
        uint256 distinctCycles,
        uint8 lowestTier,
        bool isComplete,
        uint256 baseBps,
        uint256 tierBps,
        uint256 completionBps,
        uint256 totalMultiplierBps
    ) {
        uint256 excludeCycle = currentCycle > 1 ? currentCycle : 0;

        uint256 scanFrom = totalHistoricalCycles > MAX_SCAN_CYCLES
            ? totalHistoricalCycles - MAX_SCAN_CYCLES + 1
            : 1;

        uint8 minTier = TIER_PLATINUM;
        bool hasAnyNFT = false;
        uint256 cyclesFound = 0;
        uint256 totalEligible = 0;

        if (totalHistoricalCycles == 0) {
            return (0, 0, false, BPS, BPS, BPS, BPS);
        }

        for (uint256 c = scanFrom; c <= totalHistoricalCycles; c++) {
            if (c == excludeCycle) continue;
            totalEligible++;

            uint8 bestTier = 0;
            for (uint8 t = TIER_PLATINUM; t >= TIER_BRONZE; t--) {
                if (balanceOf[c * 10 + t][user] > 0) { bestTier = t; break; }
            }
            if (bestTier > 0) {
                cyclesFound++;
                hasAnyNFT = true;
                if (bestTier < minTier) minTier = bestTier;
            }
        }

        if (!hasAnyNFT) return (0, 0, false, BPS, BPS, BPS, BPS);

        baseBps = BPS + (BASE_PER_CYCLE_BPS * cyclesFound);

        if (minTier == TIER_PLATINUM) tierBps = TIER_PLATINUM_BPS;
        else if (minTier == TIER_GOLD) tierBps = TIER_GOLD_BPS;
        else if (minTier == TIER_SILVER) tierBps = TIER_SILVER_BPS;
        else tierBps = TIER_BRONZE_BPS;

        isComplete = totalEligible > 0 && cyclesFound >= totalEligible;
        completionBps = isComplete ? COMPLETION_BONUS_BPS : BPS;

        totalMultiplierBps = baseBps * tierBps / BPS * completionBps / BPS;
        distinctCycles = cyclesFound;
        lowestTier = minTier;
    }

    // ============================================================
    //                    ERC-1155 TRANSFERS (M3 fix)
    // ============================================================

    function safeTransferFrom(
        address from, address to, uint256 id, uint256 amount, bytes calldata data
    ) external {
        require(to != address(0), "NFT: transfer to zero");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "NFT: not authorized");
        require(balanceOf[id][from] >= amount, "NFT: insufficient");
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
        emit TransferSingle(msg.sender, from, to, id, amount);

        // M3 fix: ERC-1155 receiver check
        if (_isContract(to)) {
            require(
                IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data)
                    == IERC1155Receiver.onERC1155Received.selector,
                "NFT: rejected by receiver"
            );
        }
    }

    function safeBatchTransferFrom(
        address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data
    ) external {
        require(to != address(0), "NFT: transfer to zero");
        require(ids.length == amounts.length, "NFT: length mismatch");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "NFT: not authorized");
        for (uint256 i = 0; i < ids.length; i++) {
            require(balanceOf[ids[i]][from] >= amounts[i], "NFT: insufficient");
            balanceOf[ids[i]][from] -= amounts[i];
            balanceOf[ids[i]][to] += amounts[i];
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);

        // M3 fix: ERC-1155 batch receiver check
        if (_isContract(to)) {
            require(
                IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data)
                    == IERC1155Receiver.onERC1155BatchReceived.selector,
                "NFT: rejected by receiver"
            );
        }
    }

    /// @notice M3 fix: balanceOfBatch (required by ERC-1155)
    function balanceOfBatch(
        address[] calldata accounts,
        uint256[] calldata ids
    ) external view returns (uint256[] memory) {
        require(accounts.length == ids.length, "NFT: length mismatch");
        uint256[] memory batchBalances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            batchBalances[i] = balanceOf[ids[i]][accounts[i]];
        }
        return batchBalances;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    // ============================================================
    //                    ADMIN
    // ============================================================

    function setURI(string calldata newUri) external onlySafe {
        uri = newUri;
    }

    function setVault(address newVault) external onlySafe {
        vault = newVault;
    }

    // ============================================================
    //                    INTERNALS
    // ============================================================

    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    // ERC-165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26 // ERC-1155
            || interfaceId == 0x01ffc9a7; // ERC-165
    }
}
