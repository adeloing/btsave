// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LimitedSignerModule.sol";

/**
 * @title VaultTPB — Turbo Paper Boat Vault
 * @notice ERC-4626-inspired vault for aggressive BTC accumulation strategy.
 *         Manages cycles (ATH → ATH), time-weighted gains, auto-redeem,
 *         pending pool, and entry protection.
 *
 * Strategy split: 82% WBTC (Aave) / 15% USDC (Aave) / 3% USDC (Deribit)
 *
 * @dev Priority 1 implementation: Auto-Redeem + Time-weighted + Pending Pool
 */

// Minimal ERC-20 interface
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

contract VaultTPB {
    // ============================================================
    //                        CONSTANTS
    // ============================================================

    uint256 public constant SPLIT_WBTC_BPS = 8200;   // 82%
    uint256 public constant SPLIT_USDC_AAVE_BPS = 1500; // 15%
    uint256 public constant SPLIT_USDC_DERIBIT_BPS = 300; // 3%
    uint256 public constant BPS = 10000;
    uint256 public constant MIN_NFT_DEPOSIT = 100e6;  // 100 USDC (6 decimals)
    uint256 public constant TIMELOCK_DURATION = 25 minutes;
    uint256 public constant LOCK_THRESHOLD_BPS = 500;  // ATH - 5%
    uint256 public constant PENDING_REBALANCE_THRESHOLD_BPS = 200; // 2% of TVL

    // Entry protection fee tiers
    uint256 public constant ENTRY_FEE_TIER1_BPS = 200;  // 2% (ATH-3% to ATH-1.5%)
    uint256 public constant ENTRY_FEE_TIER2_BPS = 500;  // 5% (ATH-1.5% to ATH)
    uint256 public constant ENTRY_FEE_TIER3_BPS = 800;  // 8% (above ATH)

    // ============================================================
    //                        STATE
    // ============================================================

    // --- Core ---
    IERC20 public immutable usdc;
    IERC20 public immutable wbtc;
    IAavePool public immutable aavePool;
    IChainlinkAggregator public immutable btcOracle;
    address public immutable safe; // Gnosis Safe (2/2 human)
    LimitedSignerModule public immutable lsm;

    // --- TPB Token (internal ERC-20) ---
    string public constant name = "Turbo Paper Boat";
    string public constant symbol = "TPB";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- Cycle State ---
    uint256 public currentCycle;
    uint256 public cycleStartTime;
    uint256 public cycleATH;          // ATH ratcheted for current cycle
    bool public cycleActive;
    bool public redemptionWindowOpen;

    // --- Unwind ---
    bytes32 public pendingUnwindHash;
    uint256 public unwindProposedAt;
    bool public unwindPending;

    // --- Auto-Redeem ---
    mapping(address => uint256) public autoRedeemPct; // 0-100 (%)

    // --- Time-Weighted Accounting ---
    struct UserCheckpoint {
        uint256 balance;
        uint256 timestamp;
        uint256 weightedSum;    // cumulative balance × time
    }
    mapping(address => UserCheckpoint) public userCheckpoints;
    uint256 public globalWeightedSum;
    uint256 public globalLastBalance;
    uint256 public globalLastTimestamp;

    // --- Pending Pool ---
    uint256 public pendingPoolBalance;  // USDC not yet rebalanced
    uint256 public lastRebalanceTime;

    // --- Auto-Redeem Registry ---
    address[] public autoRedeemUsers;  // Users with autoRedeemPct > 0
    mapping(address => bool) public isAutoRedeemRegistered;

    // --- Treasury ---
    address public treasury;
    uint256 public treasuryAccrued;

    // ============================================================
    //                        EVENTS
    // ============================================================

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed user, uint256 usdcAmount, uint256 tpbMinted, uint256 entryFee);
    event AutoRedeemSet(address indexed user, uint256 percent);
    event AutoRedeemExecuted(address indexed user, uint256 percent, uint256 wbtcAmount);
    event CycleStarted(uint256 indexed cycle, uint256 ath, uint256 timestamp);
    event CycleEnded(uint256 indexed cycle, uint256 timestamp, uint256 totalGains);
    event UnwindProposed(bytes32 txHash, uint256 executeAfter);
    event UnwindExecuted(uint256 indexed cycle);
    event UnwindAutoExecuted(uint256 indexed cycle, string reason);
    event LockActivated(uint256 price, uint256 athThreshold);
    event PendingPoolRebalanced(uint256 amount, uint256 timestamp);
    event CheckpointUpdated(address indexed user, uint256 balance, uint256 weightedSum);

    // ============================================================
    //                       MODIFIERS
    // ============================================================

    modifier onlySafe() {
        require(msg.sender == safe, "TPB: only Safe");
        _;
    }

    modifier onlyKeeper() {
        require(lsm.allowedKeepers(msg.sender), "TPB: only keeper");
        _;
    }

    modifier whenCycleActive() {
        require(cycleActive, "TPB: cycle not active");
        _;
    }

    // ============================================================
    //                      CONSTRUCTOR
    // ============================================================

    constructor(
        address _usdc,
        address _wbtc,
        address _aavePool,
        address _btcOracle,
        address _safe,
        address _lsm,
        address _treasury,
        uint256 _initialATH
    ) {
        usdc = IERC20(_usdc);
        wbtc = IERC20(_wbtc);
        aavePool = IAavePool(_aavePool);
        btcOracle = IChainlinkAggregator(_btcOracle);
        safe = _safe;
        lsm = LimitedSignerModule(_lsm);
        treasury = _treasury;

        cycleATH = _initialATH;
        currentCycle = 1;
        cycleStartTime = block.timestamp;
        cycleActive = true;
        redemptionWindowOpen = false;
        lastRebalanceTime = block.timestamp;
        globalLastTimestamp = block.timestamp;

        emit CycleStarted(1, _initialATH, block.timestamp);
    }

    // ============================================================
    //                    DEPOSIT (Priority 1)
    // ============================================================

    /**
     * @notice Deposit USDC into the vault. TPB tokens minted at current NAV.
     *         Entry fees applied if price is near ATH (anti-abuse).
     *         Funds go to pending pool until next rebalance.
     */
    function deposit(uint256 usdcAmount) external whenCycleActive {
        require(usdcAmount > 0, "TPB: zero deposit");

        // Calculate entry fee
        uint256 fee = _calculateEntryFee(usdcAmount);
        uint256 netAmount = usdcAmount - fee;

        // Transfer USDC from user
        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "TPB: transfer failed");

        // Accrue fee to treasury
        if (fee > 0) {
            treasuryAccrued += fee;
        }

        // Mint TPB tokens based on current NAV
        uint256 tpbToMint = _usdcToTPB(netAmount);

        // Update time-weighted checkpoint BEFORE mint (captures pre-balance)
        _updateCheckpoint(msg.sender);

        _mint(msg.sender, tpbToMint);

        // Update checkpoint balance to reflect new mint
        userCheckpoints[msg.sender].balance = balanceOf[msg.sender];
        // Update global tracking
        globalLastBalance = totalSupply;

        // Add to pending pool
        pendingPoolBalance += netAmount;

        emit Deposit(msg.sender, usdcAmount, tpbToMint, fee);
    }

    // ============================================================
    //              AUTO-REDEEM AT NEXT ATH (Priority 1)
    // ============================================================

    /**
     * @notice Set percentage to auto-redeem in WBTC at next ATH.
     * @param percent 0 to 100
     */
    function setAutoRedeemAtNextATH(uint256 percent) external {
        require(percent <= 100, "TPB: max 100%");
        require(balanceOf[msg.sender] > 0, "TPB: no position");

        // Track user in registry
        if (percent > 0 && !isAutoRedeemRegistered[msg.sender]) {
            autoRedeemUsers.push(msg.sender);
            isAutoRedeemRegistered[msg.sender] = true;
        }

        autoRedeemPct[msg.sender] = percent;
        emit AutoRedeemSet(msg.sender, percent);
    }

    // ============================================================
    //            TIME-WEIGHTED ACCOUNTING (Priority 1)
    // ============================================================

    /**
     * @notice Update user's time-weighted checkpoint.
     *         Called on every balance change (deposit, transfer, withdraw).
     */
    function _updateCheckpoint(address user) internal {
        UserCheckpoint storage cp = userCheckpoints[user];
        uint256 elapsed = block.timestamp - cp.timestamp;

        if (cp.timestamp > 0 && elapsed > 0) {
            cp.weightedSum += cp.balance * elapsed;
        }

        cp.balance = balanceOf[user];
        cp.timestamp = block.timestamp;

        // Update global
        uint256 globalElapsed = block.timestamp - globalLastTimestamp;
        if (globalElapsed > 0) {
            globalWeightedSum += globalLastBalance * globalElapsed;
        }
        globalLastBalance = totalSupply;
        globalLastTimestamp = block.timestamp;

        emit CheckpointUpdated(user, cp.balance, cp.weightedSum);
    }

    /**
     * @notice Get user's time-weighted share for current cycle.
     * @return sharesBps User's share in BPS (0-10000)
     */
    function getUserTimeWeightedShare(address user) public view returns (uint256 sharesBps) {
        UserCheckpoint memory cp = userCheckpoints[user];
        uint256 elapsed = block.timestamp - cp.timestamp;
        uint256 userWeighted = cp.weightedSum + (cp.balance * elapsed);

        uint256 globalElapsed = block.timestamp - globalLastTimestamp;
        uint256 globalTotal = globalWeightedSum + (globalLastBalance * globalElapsed);

        if (globalTotal == 0) return 0;
        return (userWeighted * BPS) / globalTotal;
    }

    // ============================================================
    //              PENDING POOL REBALANCE (Priority 1)
    // ============================================================

    /**
     * @notice Rebalance pending pool into strategy (82/15/3).
     *         Can be called weekly or when pool > 2% TVL.
     *         Only keeper or Safe can trigger.
     */
    function rebalancePendingPool() external {
        require(
            lsm.allowedKeepers(msg.sender) || msg.sender == safe,
            "TPB: unauthorized"
        );
        require(pendingPoolBalance > 0, "TPB: nothing to rebalance");

        // Check conditions: weekly OR threshold (compare pending vs deployed assets, not total)
        bool weeklyOk = block.timestamp >= lastRebalanceTime + 7 days;
        uint256 deployedAssets = _totalAssets() - pendingPoolBalance;
        bool thresholdOk = deployedAssets > 0 && pendingPoolBalance * BPS >= deployedAssets * PENDING_REBALANCE_THRESHOLD_BPS;
        require(weeklyOk || thresholdOk, "TPB: conditions not met");

        uint256 amount = pendingPoolBalance;
        pendingPoolBalance = 0;
        lastRebalanceTime = block.timestamp;

        // Split: 82% → WBTC (via swap), 15% → USDC Aave supply, 3% → Deribit
        // Actual execution delegated to LSM/keeper proposals
        // This function marks the pool as "ready for rebalance"
        // The keeper will propose the actual swap/supply txs via LSM

        emit PendingPoolRebalanced(amount, block.timestamp);
    }

    // ============================================================
    //                 ENTRY PROTECTION (Priority 2)
    // ============================================================

    /**
     * @notice Calculate entry fee based on distance to ATH.
     */
    function _calculateEntryFee(uint256 amount) internal view returns (uint256) {
        uint256 price = _getBTCPrice();

        // ATH - 3% threshold
        uint256 tier1Start = cycleATH * 9700 / BPS;  // ATH - 3%
        uint256 tier2Start = cycleATH * 9850 / BPS;  // ATH - 1.5%

        if (price < tier1Start) {
            return 0; // No fee below ATH - 3%
        } else if (price < tier2Start) {
            return amount * ENTRY_FEE_TIER1_BPS / BPS; // 2%
        } else if (price < cycleATH) {
            return amount * ENTRY_FEE_TIER2_BPS / BPS; // 5%
        } else {
            return amount * ENTRY_FEE_TIER3_BPS / BPS; // 8%
        }
    }

    /**
     * @notice View function: get current entry fee tier.
     */
    function getEntryFeeBps() external view returns (uint256) {
        uint256 price = _getBTCPrice();
        uint256 tier1Start = cycleATH * 9700 / BPS;
        uint256 tier2Start = cycleATH * 9850 / BPS;

        if (price < tier1Start) return 0;
        if (price < tier2Start) return ENTRY_FEE_TIER1_BPS;
        if (price < cycleATH) return ENTRY_FEE_TIER2_BPS;
        return ENTRY_FEE_TIER3_BPS;
    }

    // ============================================================
    //              FULL UNWIND + CYCLE RESET (Priority 3)
    // ============================================================

    /**
     * @notice Keeper proposes full unwind when new ATH detected.
     *         Starts 25-minute timelock for human validation.
     */
    function proposeUnwind() external onlyKeeper {
        uint256 price = _getBTCPrice();
        require(price >= cycleATH, "TPB: not at ATH");
        require(!unwindPending, "TPB: unwind already pending");

        unwindPending = true;
        unwindProposedAt = block.timestamp;
        redemptionWindowOpen = true;

        emit UnwindProposed(bytes32(0), block.timestamp + TIMELOCK_DURATION);
    }

    /**
     * @notice Human owners validate and execute the unwind within timelock.
     */
    function executeUnwind() external onlySafe {
        require(unwindPending, "TPB: no pending unwind");

        _performUnwind();
        emit UnwindExecuted(currentCycle);
    }

    /**
     * @notice Auto-execute unwind if timelock expired without human validation.
     *         Fail-safe: anyone can call after timelock.
     */
    function autoExecuteUnwind() external {
        require(unwindPending, "TPB: no pending unwind");
        require(
            block.timestamp >= unwindProposedAt + TIMELOCK_DURATION,
            "TPB: timelock not expired"
        );

        _performUnwind();
        emit UnwindAutoExecuted(currentCycle, "timelock expired - auto executed");
    }

    function _performUnwind() internal {
        // 1. Process auto-redeems with pro-rata if needed
        _processAutoRedeems();

        // 2. Reset cycle
        unwindPending = false;
        cycleActive = false;

        emit CycleEnded(currentCycle, block.timestamp, 0);
    }

    /**
     * @notice Process all auto-redeems at unwind. WBTC only.
     *         If total demand > available WBTC, pro-rata distribution.
     *         Remainder stays in vault for next cycle.
     */
    function _processAutoRedeems() internal {
        uint256 availableWBTC = wbtc.balanceOf(address(this));
        if (availableWBTC == 0) return;

        // Phase 1: Calculate total demand in WBTC
        uint256 totalDemandWBTC = 0;
        uint256 len = autoRedeemUsers.length;

        // Temp arrays for batch processing
        uint256[] memory demands = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address user = autoRedeemUsers[i];
            uint256 pct = autoRedeemPct[user];
            if (pct == 0 || balanceOf[user] == 0) continue;

            // User's share of vault in WBTC terms
            uint256 userTPB = balanceOf[user] * pct / 100;
            uint256 userUSDC = _tpbToUSDC(userTPB);
            uint256 btcPrice = _getBTCPrice(); // 8 decimals
            // Convert USDC (6 dec) to WBTC (8 dec): usdc * 1e8 / price * 1e2
            uint256 userWBTC = userUSDC * 1e10 / btcPrice;

            demands[i] = userWBTC;
            totalDemandWBTC += userWBTC;
        }

        if (totalDemandWBTC == 0) return;

        // Phase 2: Distribute (pro-rata if demand > available)
        bool proRata = totalDemandWBTC > availableWBTC;

        for (uint256 i = 0; i < len; i++) {
            address user = autoRedeemUsers[i];
            if (demands[i] == 0) continue;

            uint256 toSend;
            if (proRata) {
                toSend = demands[i] * availableWBTC / totalDemandWBTC;
            } else {
                toSend = demands[i];
            }

            if (toSend > 0) {
                // Burn proportional TPB
                uint256 pct = autoRedeemPct[user];
                uint256 tpbToBurn = balanceOf[user] * pct / 100;
                if (proRata) {
                    // Only burn proportion that was actually redeemed
                    tpbToBurn = tpbToBurn * toSend / demands[i];
                }
                _updateCheckpoint(user);
                _burn(user, tpbToBurn);
                userCheckpoints[user].balance = balanceOf[user];

                // Transfer WBTC
                require(wbtc.transfer(user, toSend), "TPB: WBTC transfer failed");

                emit AutoRedeemExecuted(user, pct, toSend);
            }

            // Reset auto-redeem for next cycle
            autoRedeemPct[user] = 0;
        }

        // Clean registry
        delete autoRedeemUsers;
    }

    /**
     * @notice Start new cycle after unwind. Called by Safe.
     */
    function startNewCycle(uint256 newATH) external onlySafe {
        require(!cycleActive, "TPB: cycle already active");

        currentCycle++;
        cycleATH = newATH;
        cycleStartTime = block.timestamp;
        cycleActive = true;
        redemptionWindowOpen = false;
        lastRebalanceTime = block.timestamp;

        // Clear auto-redeem registry (users were already reset in _processAutoRedeems)
        for (uint256 i = 0; i < autoRedeemUsers.length; i++) {
            isAutoRedeemRegistered[autoRedeemUsers[i]] = false;
        }
        delete autoRedeemUsers;

        // Reset global time-weighted state
        globalWeightedSum = 0;
        globalLastBalance = totalSupply;
        globalLastTimestamp = block.timestamp;

        emit CycleStarted(currentCycle, newATH, block.timestamp);
    }

    // ============================================================
    //              LOCK AT ATH - 5% (Priority 4)
    // ============================================================

    /**
     * @notice Auto-lock: close redemption window when price drops below ATH - 5%.
     *         Called by keeper. Requires price to be below threshold.
     */
    function autoLock() external onlyKeeper {
        uint256 price = _getBTCPrice();
        uint256 lockPrice = cycleATH * (BPS - LOCK_THRESHOLD_BPS) / BPS;

        require(price < lockPrice, "TPB: price above lock threshold");
        require(redemptionWindowOpen, "TPB: already locked");

        redemptionWindowOpen = false;
        emit LockActivated(price, lockPrice);
    }

    // ============================================================
    //                    INTERNAL: ERC-20
    // ============================================================

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "TPB: insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _updateCheckpoint(msg.sender);
        _updateCheckpoint(to);
        require(balanceOf[msg.sender] >= amount, "TPB: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // Update checkpoint balances after transfer
        userCheckpoints[msg.sender].balance = balanceOf[msg.sender];
        userCheckpoints[to].balance = balanceOf[to];
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _updateCheckpoint(from);
        _updateCheckpoint(to);
        require(allowance[from][msg.sender] >= amount, "TPB: allowance");
        require(balanceOf[from] >= amount, "TPB: insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        userCheckpoints[from].balance = balanceOf[from];
        userCheckpoints[to].balance = balanceOf[to];
        emit Transfer(from, to, amount);
        return true;
    }

    // ============================================================
    //                    INTERNAL: PRICING
    // ============================================================

    function _getBTCPrice() internal view returns (uint256) {
        (, int256 price,,,) = btcOracle.latestRoundData();
        require(price > 0, "TPB: invalid oracle price");
        return uint256(price); // 8 decimals from Chainlink
    }

    /**
     * @notice Total assets under management in USDC terms.
     */
    function _totalAssets() internal view returns (uint256) {
        // In production: sum of AAVE positions + Deribit equity + pending pool
        // For now: simplified
        (uint256 collateral, uint256 debt,,,,) = aavePool.getUserAccountData(safe);
        return (collateral - debt) * 1e6 / 1e8 + pendingPoolBalance; // Convert 8 dec to 6 dec
    }

    /**
     * @notice Convert USDC amount to TPB tokens based on NAV.
     */
    function _usdcToTPB(uint256 usdcAmount) internal view returns (uint256) {
        if (totalSupply == 0) {
            return usdcAmount * 1e12; // Initial: 1 USDC = 1e12 TPB (6→18 dec)
        }
        uint256 totalAssets = _totalAssets();
        if (totalAssets == 0) return usdcAmount * 1e12;
        return (usdcAmount * totalSupply) / totalAssets;
    }

    /**
     * @notice Convert TPB tokens to USDC based on NAV.
     */
    function _tpbToUSDC(uint256 tpbAmount) internal view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (tpbAmount * _totalAssets()) / totalSupply;
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    function getNav() external view returns (uint256) {
        return _totalAssets();
    }

    function getNavPerShare() external view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        return (_totalAssets() * 1e18) / totalSupply;
    }

    function getCycleInfo() external view returns (
        uint256 cycle,
        uint256 ath,
        uint256 startTime,
        bool active,
        bool redemptionOpen,
        bool unwindIsPending
    ) {
        return (currentCycle, cycleATH, cycleStartTime, cycleActive, redemptionWindowOpen, unwindPending);
    }

    function getUserInfo(address user) external view returns (
        uint256 balance,
        uint256 autoRedeem,
        uint256 timeWeightedShareBps,
        uint256 estimatedUSDC
    ) {
        return (
            balanceOf[user],
            autoRedeemPct[user],
            getUserTimeWeightedShare(user),
            _tpbToUSDC(balanceOf[user])
        );
    }

    function getAutoRedeemStats() external view returns (
        uint256 registeredUsers,
        uint256 totalDemandBps  // % of total supply requested for redeem
    ) {
        uint256 totalDemand = 0;
        for (uint256 i = 0; i < autoRedeemUsers.length; i++) {
            address user = autoRedeemUsers[i];
            if (autoRedeemPct[user] > 0 && balanceOf[user] > 0) {
                totalDemand += balanceOf[user] * autoRedeemPct[user] / 100;
            }
        }
        uint256 demandBps = totalSupply > 0 ? totalDemand * BPS / totalSupply : 0;
        return (autoRedeemUsers.length, demandBps);
    }

    // ============================================================
    //                    ADMIN (Safe 2/2)
    // ============================================================

    function setTreasury(address newTreasury) external onlySafe {
        treasury = newTreasury;
    }

    function withdrawTreasury() external onlySafe {
        uint256 amount = treasuryAccrued;
        treasuryAccrued = 0;
        require(usdc.transfer(treasury, amount), "TPB: treasury transfer failed");
    }

    function updateATH(uint256 newATH) external onlySafe {
        require(newATH > cycleATH, "TPB: ATH must increase");
        cycleATH = newATH;
    }

    /// @notice Emergency pause
    function emergencyPause() external onlySafe {
        cycleActive = false;
    }
}
