// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LimitedSignerModule v3
 * @notice Gnosis Safe Module that allows whitelisted bots to execute
 *         pre-validated transactions with hard-coded safety rules.
 *         Bots are NOT Safe owners. All critical operations require
 *         the Safe owners (2/2 human multisig).
 */

// Minimal interfaces
interface IGnosisSafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
}

interface IAavePool {
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

interface IChainlinkAggregator {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract LimitedSignerModule {
    // ============================================================
    //                        STATE
    // ============================================================

    IGnosisSafe public immutable safe;
    IAavePool public immutable aavePool;
    IChainlinkAggregator public immutable wbtcOracle;

    bool public killed;

    // --- General params ---
    uint256 public maxGasPrice = 80 gwei;
    uint256 public maxDailyTx = 20;
    uint256 public botThreshold = 2;

    // --- Aave params ---
    uint256 public borrowPerStepBase = 12_480e6; // USDC 6 decimals
    uint256 public minHealthFactor = 1.55e18;
    uint256 public maxVolatilityBps = 400; // 4%
    uint256 public borrowCooldown = 300; // 5 min

    // --- Swap params ---
    uint256 public maxSlippageBps = 35; // 0.35%

    // --- Rate limiting ---
    uint256 public maxDailyBorrowVolume = 62_400e6; // 5 steps/day
    uint256 public maxDailySwapVolume = 62_400e6;

    // --- Rebalancing ---
    uint256 public maxRebalanceBps = 200; // 2%

    // --- TVL cap ---
    uint256 public maxBorrowTvlBps = 400; // 4% of TVL per tx

    // --- R20: Max daily borrow as % of TVL ---
    uint256 public maxDailyBorrowTvlBps = 1200; // 12% of TVL per day

    // --- F2: Proposal TTL (default 30 min) ---
    uint256 public proposalTTL = 1800;

    // --- F1: Emergency gas override tracking ---
    bool public emergencyGasActive;

    // --- NC2: Repay selectors (bypass HF check — repaying improves HF) ---
    // Aave repay(address,uint256,uint256,address) = 0x573ade81
    // Aave repayWithATokens(address,uint256,uint256) = 0x35ea6a75 — actually 0x2dad97d4
    mapping(bytes4 => bool) public isRepaySelector;

    // --- Whitelists ---
    mapping(address => bool) public allowedTargets;
    mapping(address => mapping(bytes4 => bool)) public allowedSelectors;
    mapping(address => bool) public allowedKeepers;
    mapping(address => bool) public authorizedBots;
    mapping(address => bytes32) public expectedCodeHash;

    // --- Daily tracking ---
    uint256 public dailyResetTimestamp;
    uint256 public dailyTxCount;
    uint256 public dailyBorrowVolume;
    uint256 public dailySwapVolume;

    // --- Cooldown tracking ---
    mapping(bytes4 => uint256) public lastExecTime; // selector => timestamp

    // --- Tx proposals ---
    enum TxStatus { NONE, PENDING, EXECUTED, CANCELLED }

    struct Proposal {
        address to;
        uint256 value;
        bytes data;
        TxStatus status;
        uint256 timestamp;
        uint256 approvalCount;
        mapping(address => bool) approvals;
    }

    mapping(bytes32 => Proposal) internal proposals;
    uint256 public proposalCount;

    // ============================================================
    //                        EVENTS
    // ============================================================

    event TxProposed(bytes32 indexed txHash, address indexed keeper, address to, bytes4 selector);
    event TxApproved(bytes32 indexed txHash, address indexed bot);
    event TxRejected(bytes32 indexed txHash, address indexed bot, string reason);
    event TxExecuted(bytes32 indexed txHash, address to, bool success);
    event KillSwitchActivated(address indexed owner);
    event KillSwitchDeactivated(address indexed owner);
    event BotRotated(address indexed oldBot, address indexed newBot);
    event RuleViolation(bytes32 indexed txHash, uint8 ruleNumber, string rule, string details);
    event DailyLimitReset(uint256 timestamp);
    event EmergencyActionTriggered(bytes32 indexed txHash, string reason);

    // ============================================================
    //                       MODIFIERS
    // ============================================================

    modifier onlySafe() {
        require(msg.sender == address(safe), "LSM: only Safe");
        _;
    }

    modifier notKilled() {
        require(!killed, "LSM: module killed");
        _;
    }

    modifier onlyKeeper() {
        require(allowedKeepers[msg.sender], "LSM: unauthorized proposer");
        _;
    }

    modifier onlyBot() {
        require(authorizedBots[msg.sender], "LSM: unauthorized bot");
        _;
    }

    modifier onlyKeeperOrBot() {
        require(
            allowedKeepers[msg.sender] || authorizedBots[msg.sender],
            "LSM: unauthorized executor"
        );
        _;
    }

    // ============================================================
    //                      CONSTRUCTOR
    // ============================================================

    constructor(
        address _safe,
        address _aavePool,
        address _wbtcOracle
    ) {
        safe = IGnosisSafe(_safe);
        aavePool = IAavePool(_aavePool);
        wbtcOracle = IChainlinkAggregator(_wbtcOracle);
        dailyResetTimestamp = block.timestamp;

        // NC2: Aave repay selectors bypass HF pre-check (repaying always improves HF)
        isRepaySelector[0x573ade81] = true; // repay(address,uint256,uint256,address)
    }

    // ============================================================
    //                   PROPOSAL & APPROVAL
    // ============================================================

    /**
     * @notice Keeper proposes a transaction. Checks applied at proposal time:
     *   R1  — Proposant must be whitelisted keeper (onlyKeeper modifier)
     *   R2  — Target address must be whitelisted
     *   R3  — Function selector must be whitelisted for target
     *   R4  — Module must not be killed (notKilled modifier)
     *   R6  — No raw ETH transfers (value must be 0)
     *   R9  — Target code hash must match pinned hash (1inch, Aave Pool, Oracle)
     */
    function proposeTransaction(
        address to,
        bytes calldata data,
        uint256 value
    ) external onlyKeeper notKilled returns (bytes32 txHash) {
        // R2: target whitelisted
        require(allowedTargets[to], "LSM: target not whitelisted");

        // R3: selector whitelisted
        bytes4 selector = bytes4(data[:4]);
        require(allowedSelectors[to][selector], "LSM: function not allowed");

        // R6: no raw ETH transfer (unless whitelisted target)
        require(value == 0, "LSM: no raw ETH transfer");

        // R9: code hash check
        bytes32 codeHash;
        assembly { codeHash := extcodehash(to) }
        if (expectedCodeHash[to] != bytes32(0)) {
            require(codeHash == expectedCodeHash[to], "LSM: target code changed");
        }

        // H2 fix: use abi.encode instead of abi.encodePacked to prevent hash collisions
        txHash = keccak256(abi.encode(to, data, value, block.timestamp, proposalCount));
        proposalCount++;

        Proposal storage p = proposals[txHash];
        p.to = to;
        p.value = value;
        p.data = data;
        p.status = TxStatus.PENDING;
        p.timestamp = block.timestamp;

        emit TxProposed(txHash, msg.sender, to, selector);
    }

    /**
     * @notice Bot approves a pending transaction.
     */
    function approveTx(bytes32 txHash) external onlyBot notKilled {
        Proposal storage p = proposals[txHash];
        require(p.status == TxStatus.PENDING, "LSM: not pending");
        require(!p.approvals[msg.sender], "LSM: already approved");

        p.approvals[msg.sender] = true;
        p.approvalCount++;

        emit TxApproved(txHash, msg.sender);
    }

    /**
     * @notice Bot rejects a pending transaction (logging only).
     */
    function rejectTx(bytes32 txHash, string calldata reason) external onlyBot {
        emit TxRejected(txHash, msg.sender, reason);
    }

    /**
     * @notice Execute after threshold approvals. Re-checks ALL rules on-chain:
     *   R4  — Module not killed (notKilled modifier)
     *   R5  — Gas price ≤ maxGasPrice (80 gwei default)
     *   R7  — No transfer/transferFrom to non-whitelisted address
     *   R8  — Bot approval count ≥ botThreshold (2/3)
     *   R10 — Cooldown between executions of same selector (300s default)
     *   R12 — Daily transaction count < maxDailyTx (20 default)
     *   R14 — Health Factor ≥ 1.72 (checked PRE and POST execution, atomic revert)
     *
     *   Off-chain validators (called by bots before approving):
     *   R11 — Daily borrow volume ≤ maxDailyBorrowVolume (validateBorrow)
     *   R13 — Borrow amount ≤ borrowPerStepBase × 1.25 (validateBorrow)
     *   R15 — No borrow if price volatility > 4% in 10min (bot-side oracle check)
     *   R16 — 1inch slippage ≤ 0.35% (bot-side simulation)
     *   R17 — Options only if extra WBTC ≥ threshold (bot-side balance check)
     *   R18 — Rebalance amount ≤ 2% of total position (bot-side check)
     *   R19 — Borrow amount ≤ 4% of TVL (validateBorrow)
     *   R20 — Daily borrow ≤ 12% of TVL (on-chain + validateBorrow)
     */
    /**
     * @notice Execute after threshold approvals. F3: only keeper or bot can call.
     */
    function executeIfReady(bytes32 txHash) external onlyKeeperOrBot notKilled {
        Proposal storage p = proposals[txHash];
        require(p.status == TxStatus.PENDING, "LSM: not pending");

        // F2: TTL — proposal must not be expired
        require(block.timestamp <= p.timestamp + proposalTTL, "LSM: proposal expired");

        // R8: threshold
        require(p.approvalCount >= botThreshold, "LSM: insufficient bot signatures");

        // Reset daily counters if new day
        _resetDailyIfNeeded();

        // R12: max daily tx
        require(dailyTxCount < maxDailyTx, "LSM: daily tx limit reached");

        // R5: gas price
        require(tx.gasprice <= maxGasPrice, "LSM: gas too high");

        bytes4 selector;
        bytes memory d = p.data;
        assembly { selector := mload(add(d, 32)) }

        // R10: cooldown
        require(
            block.timestamp - lastExecTime[selector] >= borrowCooldown,
            "LSM: cooldown active"
        );

        // R7: no unauthorized token transfers
        _checkNoUnauthorizedTransfer(p.to, p.data);

        // R14 pre-check: HF before (NC2: skip for repay operations — repaying improves HF)
        if (!isRepaySelector[selector]) {
            _checkHealthFactor();
        }

        // --- Execute ---
        p.status = TxStatus.EXECUTED;
        dailyTxCount++;
        lastExecTime[selector] = block.timestamp;

        bool success = safe.execTransactionFromModule(
            p.to,
            p.value,
            p.data,
            0 // Call
        );

        // R14 post-check: HF after (always checked, even for repay — ensures no regression)
        _checkHealthFactor();

        // Volume tracking for borrow and swap operations
        if (selector == 0xa415bcad) {  // Aave borrow
            uint256 amount;
            assembly { amount := mload(add(d, 68)) }  // Second uint256 parameter
            require(dailyBorrowVolume + amount <= maxDailyBorrowVolume, "LSM: daily borrow limit exceeded");

            // R20: daily borrow ≤ 12% of TVL
            (uint256 totalCollateral,,,,,) = aavePool.getUserAccountData(address(safe));
            require(
                dailyBorrowVolume + amount <= totalCollateral * maxDailyBorrowTvlBps / 10000,
                "LSM: daily borrow exceeds TVL cap (R20)"
            );

            dailyBorrowVolume += amount;
        } else if (selector == 0x12aa3caf) {  // 1inch swap
            uint256 amount;
            assembly { amount := mload(add(d, 68)) }  // Second uint256 parameter  
            require(dailySwapVolume + amount <= maxDailySwapVolume, "LSM: daily swap limit exceeded");
            dailySwapVolume += amount;
        }

        // F1: auto-reset emergency gas override after execution
        if (emergencyGasActive) {
            maxGasPrice = 80 gwei;
            emergencyGasActive = false;
        }

        require(success, "LSM: execution failed");
        emit TxExecuted(txHash, p.to, success);
    }

    // ============================================================
    //                    RULE CHECKS (INTERNAL)
    // ============================================================

    function _checkHealthFactor() internal view {
        (,,,,, uint256 hf) = aavePool.getUserAccountData(address(safe));
        // Only check if there's active debt
        if (hf != type(uint256).max) {
            require(hf >= minHealthFactor, "LSM: HF too low");
        }
    }

    function _checkNoUnauthorizedTransfer(address to, bytes memory data) internal view {
        if (data.length < 4) return;
        bytes4 sel = bytes4(data);
        // transfer(address,uint256) = 0xa9059cbb
        // transferFrom(address,address,uint256) = 0x23b872dd
        // approve(address,uint256) = 0x095ea7b3
        if (sel == 0xa9059cbb) {
            address recipient;
            assembly { recipient := mload(add(data, 36)) }
            require(allowedTargets[recipient], "LSM: unauthorized token transfer");
        } else if (sel == 0x23b872dd) {
            address recipient;
            assembly { recipient := mload(add(data, 68)) }
            require(allowedTargets[recipient], "LSM: unauthorized token transfer");
        } else if (sel == 0x095ea7b3) {
            address spender;
            assembly { spender := mload(add(data, 36)) }
            require(allowedTargets[spender], "LSM: unauthorized token approval");
        }
    }

    function _resetDailyIfNeeded() internal {
        if (block.timestamp >= dailyResetTimestamp + 1 days) {
            dailyResetTimestamp = block.timestamp;
            dailyTxCount = 0;
            dailyBorrowVolume = 0;
            dailySwapVolume = 0;
            emit DailyLimitReset(block.timestamp);
        }
    }

    // ============================================================
    //              SPECIFIC OPERATION VALIDATORS
    // ============================================================

    /**
     * @notice Off-chain validator for borrow operations. Checks:
     *   R13 — Borrow amount ≤ borrowPerStepBase × 1.25
     *   R19 — Borrow amount ≤ 4% of current TVL (totalCollateral)
     *   R14 — Current Health Factor ≥ minHealthFactor (1.72)
     *   R11 — Daily borrow volume within limit
     */
    function validateBorrow(uint256 amount) external view returns (bool, string memory) {
        // R13: amount <= step * 1.25
        if (amount > borrowPerStepBase * 125 / 100) {
            return (false, "LSM: borrow amount exceeded");
        }

        // R19: amount <= 4% of TVL
        (uint256 totalCollateral,,,,, uint256 hf) = aavePool.getUserAccountData(address(safe));
        if (amount > totalCollateral * maxBorrowTvlBps / 10000) {
            return (false, "LSM: borrow exceeds TVL cap");
        }

        // R14: HF check
        if (hf != type(uint256).max && hf < minHealthFactor) {
            return (false, "LSM: HF too low");
        }

        // R11: daily volume
        if (dailyBorrowVolume + amount > maxDailyBorrowVolume) {
            return (false, "LSM: daily volume exceeded");
        }

        // R20: daily borrow ≤ 12% of TVL
        if (dailyBorrowVolume + amount > totalCollateral * maxDailyBorrowTvlBps / 10000) {
            return (false, "LSM: daily borrow exceeds TVL cap (R20)");
        }

        return (true, "");
    }

    /**
     * @notice Off-chain validator for swap operations.
     *   R16 — Slippage check is bot-side (simulation vs oracle)
     *   R11 — Daily swap volume within limit
     */
    function validateSwap(uint256 amount) external view returns (bool, string memory) {
        if (dailySwapVolume + amount > maxDailySwapVolume) {
            return (false, "LSM: daily swap volume exceeded");
        }
        return (true, "");
    }

    /**
     * @notice Check all rules for a proposed tx (view function for bots).
     */
    function isAllowedTransaction(
        address to,
        bytes calldata data,
        uint256 value
    ) external view returns (bool allowed, string memory reason) {
        if (killed) return (false, "LSM: module killed");
        if (!allowedTargets[to]) return (false, "LSM: target not whitelisted");

        bytes4 selector = bytes4(data[:4]);
        if (!allowedSelectors[to][selector]) return (false, "LSM: function not allowed");
        if (value != 0) return (false, "LSM: no raw ETH transfer");
        if (tx.gasprice > maxGasPrice) return (false, "LSM: gas too high");

        // Code hash
        bytes32 codeHash;
        assembly { codeHash := extcodehash(to) }
        if (expectedCodeHash[to] != bytes32(0) && codeHash != expectedCodeHash[to]) {
            return (false, "LSM: target code changed");
        }

        return (true, "");
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    function getPendingTx(bytes32 txHash) external view returns (
        address to,
        uint256 value,
        uint256 approvals,
        uint256 timestamp,
        TxStatus status
    ) {
        Proposal storage p = proposals[txHash];
        return (p.to, p.value, p.approvalCount, p.timestamp, p.status);
    }

    function getDailyStats() external view returns (
        uint256 txCount,
        uint256 borrowVolume,
        uint256 swapVolume
    ) {
        return (dailyTxCount, dailyBorrowVolume, dailySwapVolume);
    }

    function hasApproved(bytes32 txHash, address bot) external view returns (bool) {
        return proposals[txHash].approvals[bot];
    }

    // ============================================================
    //               ADMIN FUNCTIONS (Safe 2/2 only)
    // ============================================================

    function setTarget(address target, bool allowed, bytes32 _codeHash) external onlySafe {
        allowedTargets[target] = allowed;
        expectedCodeHash[target] = _codeHash;
    }

    function setSelector(address target, bytes4 selector, bool allowed) external onlySafe {
        allowedSelectors[target][selector] = allowed;
    }

    function setKeeper(address keeper, bool allowed) external onlySafe {
        allowedKeepers[keeper] = allowed;
    }

    function setBot(address bot, bool allowed) external onlySafe {
        authorizedBots[bot] = allowed;
    }

    function rotateBotKey(address oldBot, address newBot) external onlySafe {
        require(authorizedBots[oldBot], "LSM: old bot not authorized");
        require(!authorizedBots[newBot], "LSM: new bot already authorized");
        authorizedBots[oldBot] = false;
        authorizedBots[newBot] = true;
        emit BotRotated(oldBot, newBot);
    }

    function killSwitch() external onlySafe {
        killed = true;
        emit KillSwitchActivated(msg.sender);
    }

    function revive() external onlySafe {
        killed = false;
        emit KillSwitchDeactivated(msg.sender);
    }

    function setMaxGasPrice(uint256 newMax) external onlySafe {
        maxGasPrice = newMax;
    }

    function setMinHealthFactor(uint256 newMin) external onlySafe {
        minHealthFactor = newMin;
    }

    function setBorrowPerStepBase(uint256 newBase) external onlySafe {
        borrowPerStepBase = newBase;
    }

    function setMaxDailyTx(uint256 newMax) external onlySafe {
        maxDailyTx = newMax;
    }

    function setMaxDailyBorrowVolume(uint256 newMax) external onlySafe {
        maxDailyBorrowVolume = newMax;
    }

    function setMaxDailySwapVolume(uint256 newMax) external onlySafe {
        maxDailySwapVolume = newMax;
    }

    function setBorrowCooldown(uint256 newCooldown) external onlySafe {
        borrowCooldown = newCooldown;
    }

    function setBotThreshold(uint256 newThreshold) external onlySafe {
        require(newThreshold > 0, "LSM: threshold must be > 0");
        botThreshold = newThreshold;
    }

    function setMaxBorrowTvlBps(uint256 newBps) external onlySafe {
        maxBorrowTvlBps = newBps;
    }

    function setMaxDailyBorrowTvlBps(uint256 newBps) external onlySafe {
        maxDailyBorrowTvlBps = newBps;
    }

    function setProposalTTL(uint256 newTTL) external onlySafe {
        require(newTTL >= 60, "LSM: TTL too short");
        proposalTTL = newTTL;
    }

    function setRepaySelector(bytes4 selector, bool allowed) external onlySafe {
        isRepaySelector[selector] = allowed;
    }

    /**
     * @notice F1: Emergency override for high gas situations (human-only).
     *         Sets maxGasPrice to max until next executeIfReady, then auto-resets to 80 gwei.
     */
    function emergencyHighGas() external onlySafe {
        maxGasPrice = type(uint256).max;
        emergencyGasActive = true;
    }

    /**
     * @notice Record borrow volume manually (keeper/bot only).
     *         Used when bot validates amounts off-chain.
     */
    function recordBorrowVolume(uint256 amount) external onlyKeeperOrBot {
        _resetDailyIfNeeded();
        require(dailyBorrowVolume + amount <= maxDailyBorrowVolume, "LSM: daily borrow limit exceeded");
        dailyBorrowVolume += amount;
    }

    /**
     * @notice Record swap volume manually (keeper/bot only).
     *         Used when bot validates amounts off-chain.
     */
    function recordSwapVolume(uint256 amount) external onlyKeeperOrBot {
        _resetDailyIfNeeded();
        require(dailySwapVolume + amount <= maxDailySwapVolume, "LSM: daily swap limit exceeded");
        dailySwapVolume += amount;
    }
}
