// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NFTBonus — BTSAVE Cycle NFT Collection (ERC-1155)
 * @notice Mints 1 NFT per cycle per eligible user. 4 tiers: Bronze, Silver, Gold, Platinum.
 *         Bonus calculated from current collection at cycle end (no permanent memory).
 *
 * Token ID encoding: cycleNumber * 10 + tier
 *   tier: 1=Bronze, 2=Silver, 3=Gold, 4=Platinum
 *   Example: cycle 3 Gold = tokenId 34
 *
 * Bonus Formula:
 *   BonusMultiplier = Base × TierQuality × Completion
 *   - Base = 1 + 0.12 × C  (C = distinct cycles in collection)
 *   - TierQuality: 1.00 (Bronze), 1.20 (Silver+), 1.45 (Gold+), 1.75 (Platinum)
 *   - Completion: 1.35 if user holds NFT for every historical cycle, else 1.00
 */
contract NFTBonus {
    // ============================================================
    //                        CONSTANTS
    // ============================================================

    uint8 public constant TIER_BRONZE = 1;
    uint8 public constant TIER_SILVER = 2;
    uint8 public constant TIER_GOLD = 3;
    uint8 public constant TIER_PLATINUM = 4;

    // Bonus multipliers in BPS (10000 = 1.00×)
    uint256 public constant BASE_PER_CYCLE_BPS = 1200;     // 0.12 per cycle
    uint256 public constant TIER_BRONZE_BPS = 10000;        // 1.00×
    uint256 public constant TIER_SILVER_BPS = 12000;        // 1.20×
    uint256 public constant TIER_GOLD_BPS = 14500;          // 1.45×
    uint256 public constant TIER_PLATINUM_BPS = 17500;       // 1.75×
    uint256 public constant COMPLETION_BONUS_BPS = 13500;    // 1.35×
    uint256 public constant BPS = 10000;

    // ============================================================
    //                        STATE
    // ============================================================

    address public vault;      // VaultTPB address (minter)
    address public safe;       // Gnosis Safe (admin)
    uint256 public currentCycle;

    // ERC-1155 state
    // tokenId = cycle * 10 + tier
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    // Track which cycles have been minted (for completion check)
    uint256 public totalHistoricalCycles;

    // URI
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

    /**
     * @notice Mint NFT for a user at end of cycle. Called by VaultTPB.
     * @param user Address to mint to
     * @param cycle Cycle number
     * @param tier 1=Bronze, 2=Silver, 3=Gold, 4=Platinum
     */
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

    /**
     * @notice Update the current cycle (called by vault at cycle start).
     */
    function setCycle(uint256 newCycle) external onlyVault {
        currentCycle = newCycle;
    }

    // ============================================================
    //                    BONUS CALCULATION
    // ============================================================

    /**
     * @notice Calculate bonus multiplier for a user based on current NFT collection.
     *         No permanent memory — reads current balances only.
     * @return multiplierBps Bonus multiplier in BPS (10000 = 1.00×, 22000 = 2.20×, etc.)
     */
    function getBonusMultiplier(address user) external view returns (uint256 multiplierBps) {
        if (totalHistoricalCycles == 0) return BPS; // No cycles yet

        // Determine which cycle to exclude (current cycle, except cycle 1)
        uint256 excludeCycle = currentCycle > 1 ? currentCycle : 0;

        // Scan all historical cycles
        uint256 distinctCycles = 0;
        uint8 minTier = TIER_PLATINUM; // Start with highest, find lowest
        bool hasAnyNFT = false;
        uint256 cyclesWithNFT = 0;

        for (uint256 c = 1; c <= totalHistoricalCycles; c++) {
            if (c == excludeCycle) continue;

            // Find best tier for this cycle
            uint8 bestTier = 0;
            for (uint8 t = TIER_PLATINUM; t >= TIER_BRONZE; t--) {
                uint256 tokenId = c * 10 + t;
                if (balanceOf[tokenId][user] > 0) {
                    bestTier = t;
                    break;
                }
            }

            if (bestTier > 0) {
                distinctCycles++;
                cyclesWithNFT++;
                hasAnyNFT = true;
                if (bestTier < minTier) {
                    minTier = bestTier;
                }
            }
        }

        if (!hasAnyNFT) return BPS; // No NFTs = 1.00×

        // Base = 1 + 0.12 × C
        uint256 baseBps = BPS + (BASE_PER_CYCLE_BPS * distinctCycles);

        // TierQuality = based on LOWEST tier in collection (all must be X or better)
        uint256 tierBps;
        if (minTier == TIER_PLATINUM) tierBps = TIER_PLATINUM_BPS;
        else if (minTier == TIER_GOLD) tierBps = TIER_GOLD_BPS;
        else if (minTier == TIER_SILVER) tierBps = TIER_SILVER_BPS;
        else tierBps = TIER_BRONZE_BPS;

        // Completion = 1.35 if user has NFT for EVERY historical cycle (excluding current)
        // Count eligible cycles: all historical cycles minus current if it's within range
        uint256 totalEligibleCycles = totalHistoricalCycles;
        if (excludeCycle > 0 && excludeCycle <= totalHistoricalCycles) {
            totalEligibleCycles = totalHistoricalCycles - 1;
        }
        uint256 completionBps;
        if (totalEligibleCycles > 0 && cyclesWithNFT >= totalEligibleCycles) {
            completionBps = COMPLETION_BONUS_BPS;
        } else {
            completionBps = BPS;
        }

        // BonusMultiplier = Base × TierQuality × Completion
        // All in BPS: (baseBps * tierBps * completionBps) / BPS^2
        multiplierBps = baseBps * tierBps / BPS * completionBps / BPS;
    }

    /**
     * @notice Get detailed bonus breakdown for a user.
     */
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

        uint8 minTier = TIER_PLATINUM;
        bool hasAnyNFT = false;
        uint256 cyclesFound = 0;

        uint256 totalEligible = totalHistoricalCycles;
        if (excludeCycle > 0 && excludeCycle <= totalHistoricalCycles) {
            totalEligible = totalHistoricalCycles - 1;
        }
        if (totalEligible == 0 && totalHistoricalCycles == 0) {
            return (0, 0, false, BPS, BPS, BPS, BPS);
        }

        for (uint256 c = 1; c <= totalHistoricalCycles; c++) {
            if (c == excludeCycle) continue;
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
    //                    ERC-1155 TRANSFERS
    // ============================================================

    function safeTransferFrom(
        address from, address to, uint256 id, uint256 amount, bytes calldata
    ) external {
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "NFT: not authorized");
        require(balanceOf[id][from] >= amount, "NFT: insufficient");
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
        emit TransferSingle(msg.sender, from, to, id, amount);
    }

    function safeBatchTransferFrom(
        address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata
    ) external {
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "NFT: not authorized");
        for (uint256 i = 0; i < ids.length; i++) {
            require(balanceOf[ids[i]][from] >= amounts[i], "NFT: insufficient");
            balanceOf[ids[i]][from] -= amounts[i];
            balanceOf[ids[i]][to] += amounts[i];
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
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

    // ERC-165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26 // ERC-1155
            || interfaceId == 0x01ffc9a7; // ERC-165
    }
}
