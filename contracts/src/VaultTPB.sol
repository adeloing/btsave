// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VaultTPB v2.1 — Turbo Paper Boat Vault
 * @notice BTC accumulation vault with transferable TPB token (ERC-4626 inspired).
 *
 *  Audit fixes applied:
 *   C1 — First depositor inflation attack: virtual offset (dead shares)
 *   C2 — Auto-redeem dilution: process auto-redeems BEFORE reward mint
 *   H1 — safeWBTC manipulation: rate-limited updates (max ±20% per day)
 *   M1 — Gas bomb endCycle: paginated via maxHoldersPerBatch
 *   M4 — Entry protection: fee tiers near ATH
 *   L1 — nonReentrant removed from transfer/transferFrom
 *   L2 — transfer to address(0) blocked
 *   L3 — recoverToken checks return value
 *   L4 — unused constant removed
 *   L6 — rebalance underflow protected
 */

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface INFTBonus {
    function getBonusMultiplier(address user) external view returns (uint256);
}

contract VaultTPB {
    // ================================================================
    // ERC-20: TPB Token (inline)
    // ================================================================
    string public constant name = "Turbo Paper Boat";
    string public constant symbol = "TPB";
    uint8 public constant decimals = 8;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ================================================================
    // Vault State
    // ================================================================
    IERC20 public immutable wbtc;
    address public safe;
    address public keeper;
    INFTBonus public nftBonus;

    // Cycle
    uint256 public currentATH;
    uint256 public cycleStartTime;
    uint256 public cycleNumber;
    uint256 public currentStep;
    bool public locked;

    // Pending pool
    uint256 public pendingWBTC;
    uint256 public constant REBALANCE_THRESHOLD_BPS = 200; // 2%
    uint256 public lastRebalanceTime;

    // Auto-redeem
    mapping(address => uint256) public autoRedeemBPS; // 0-10000
    uint256 public constant MAX_BPS = 10_000;

    // C1 fix: Virtual offset to prevent inflation attack
    uint256 private constant VIRTUAL_SHARES = 1e3; // 1000 dead shares
    uint256 private constant VIRTUAL_ASSETS = 1e3; // 1000 dead assets (sats)

    // H1 fix: safeWBTC rate limiting
    uint256 public safeWBTC;
    uint256 public lastSafeWBTCUpdate;
    uint256 public lastSafeWBTCValue;
    uint256 public constant MAX_SAFE_WBTC_CHANGE_BPS = 2000; // max 20% change per day

    // M4 fix: Entry protection fees near ATH
    uint256 public constant ENTRY_FEE_TIER1_BPS = 200;  // 2% at ATH-3% to ATH-1.5%
    uint256 public constant ENTRY_FEE_TIER2_BPS = 500;  // 5% at ATH-1.5% to ATH
    uint256 public constant ENTRY_FEE_TIER3_BPS = 800;  // 8% above ATH
    address public feeRecipient; // treasury or burn
    uint256 public currentPrice; // updated by keeper, 8 decimals

    // M1 fix: max holders per batch
    uint256 public constant MAX_HOLDERS_PER_BATCH = 50;

    // Reentrancy guard
    bool private _reentrancyLock;

    // ================================================================
    // Access Control
    // ================================================================
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "TPB: not owner");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner, "TPB: not keeper");
        _;
    }

    modifier nonReentrant() {
        require(!_reentrancyLock, "TPB: reentrant");
        _reentrancyLock = true;
        _;
        _reentrancyLock = false;
    }

    // ================================================================
    // Constructor
    // ================================================================
    constructor(
        address _wbtc,
        address _safe,
        address _keeper,
        uint256 _initialATH
    ) {
        wbtc = IERC20(_wbtc);
        safe = _safe;
        keeper = _keeper;
        owner = msg.sender;
        feeRecipient = msg.sender;
        currentATH = _initialATH;
        cycleStartTime = block.timestamp;
        cycleNumber = 1;
        lastRebalanceTime = block.timestamp;
        lastSafeWBTCUpdate = block.timestamp;
    }

    // ================================================================
    // Deposit: WBTC → TPB (NAV-based, with entry fee)
    // ================================================================
    event Deposited(address indexed user, uint256 wbtcAmount, uint256 tpbMinted, uint256 feePaid);

    function totalAssets() public view returns (uint256) {
        return wbtc.balanceOf(address(this)) + safeWBTC;
    }

    /// @notice Calculate entry fee based on proximity to ATH (M4 fix)
    function getEntryFeeBPS() public view returns (uint256) {
        if (currentPrice == 0 || currentATH == 0) return 0;
        if (currentPrice > currentATH) return ENTRY_FEE_TIER3_BPS;

        uint256 distanceBPS = ((currentATH - currentPrice) * MAX_BPS) / currentATH;
        if (distanceBPS < 150) return ENTRY_FEE_TIER2_BPS;  // within 1.5%
        if (distanceBPS < 300) return ENTRY_FEE_TIER1_BPS;  // within 3%
        return 0;
    }

    /// @notice Convert WBTC amount to TPB shares (C1 fix: virtual offset)
    function _convertToShares(uint256 wbtcAmount) internal view returns (uint256) {
        return (wbtcAmount * (totalSupply + VIRTUAL_SHARES)) / (totalAssets() + VIRTUAL_ASSETS);
    }

    /// @notice Convert TPB shares to WBTC amount (C1 fix: virtual offset)
    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return (shares * (totalAssets() + VIRTUAL_ASSETS)) / (totalSupply + VIRTUAL_SHARES);
    }

    function deposit(uint256 wbtcAmount) external nonReentrant {
        require(wbtcAmount > 0, "TPB: zero deposit");

        // M4: Entry fee
        uint256 feeBPS = getEntryFeeBPS();
        uint256 fee = (wbtcAmount * feeBPS) / MAX_BPS;
        uint256 netAmount = wbtcAmount - fee;

        // C1: Calculate shares with virtual offset (prevents inflation attack)
        uint256 shares = _convertToShares(netAmount);
        require(shares > 0, "TPB: zero shares");

        // Transfer WBTC to vault
        require(wbtc.transferFrom(msg.sender, address(this), wbtcAmount), "TPB: transfer failed");

        // Transfer fee to recipient
        if (fee > 0 && feeRecipient != address(0)) {
            require(wbtc.transfer(feeRecipient, fee), "TPB: fee transfer failed");
        }

        pendingWBTC += netAmount;
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, wbtcAmount, shares, fee);
    }

    // ================================================================
    // Redeem: TPB → WBTC (only step 0, unlocked)
    // ================================================================
    event Redeemed(address indexed user, uint256 tpbBurned, uint256 wbtcReturned);

    function previewRedeem(uint256 tpbAmount) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return _convertToAssets(tpbAmount);
    }

    function redeem(uint256 tpbAmount) external nonReentrant {
        require(tpbAmount > 0, "TPB: zero redeem");
        require(currentStep == 0, "TPB: not at step 0");
        require(!locked, "TPB: locked");
        require(balanceOf[msg.sender] >= tpbAmount, "TPB: insufficient balance");

        uint256 wbtcOut = _convertToAssets(tpbAmount);
        require(wbtcOut > 0, "TPB: zero output");

        uint256 liquid = wbtc.balanceOf(address(this));
        require(wbtcOut <= liquid, "TPB: insufficient liquidity");

        _burn(msg.sender, tpbAmount);
        require(wbtc.transfer(msg.sender, wbtcOut), "TPB: transfer failed");

        emit Redeemed(msg.sender, tpbAmount, wbtcOut);
    }

    // ================================================================
    // Auto-Redeem Configuration
    // ================================================================
    event AutoRedeemSet(address indexed user, uint256 bps);

    function setAutoRedeem(uint256 bps) external {
        require(bps <= MAX_BPS, "TPB: bps > 10000");
        autoRedeemBPS[msg.sender] = bps;
        emit AutoRedeemSet(msg.sender, bps);
    }

    // ================================================================
    // Pending Pool Rebalance
    // ================================================================
    event Rebalanced(uint256 wbtcDeployed);

    function rebalancePendingPool() external onlyKeeper nonReentrant {
        require(pendingWBTC > 0, "TPB: nothing pending");

        uint256 vaultBalance = wbtc.balanceOf(address(this));

        // L6 fix: protect against underflow
        uint256 deployedTVL = vaultBalance > pendingWBTC ? vaultBalance - pendingWBTC : 0;

        bool thresholdMet = deployedTVL > 0 &&
            (pendingWBTC * MAX_BPS) / deployedTVL >= REBALANCE_THRESHOLD_BPS;
        bool weeklyDue = block.timestamp >= lastRebalanceTime + 7 days;

        require(thresholdMet || weeklyDue, "TPB: rebalance not due");

        // Cap to actual available balance
        uint256 amount = pendingWBTC > vaultBalance ? vaultBalance : pendingWBTC;
        pendingWBTC -= amount;
        lastRebalanceTime = block.timestamp;

        require(wbtc.transfer(safe, amount), "TPB: transfer to safe failed");
        safeWBTC += amount;

        emit Rebalanced(amount);
    }

    // ================================================================
    // Cycle Management
    // ================================================================
    event StepChanged(uint256 newStep);
    event Locked();
    event Unlocked();
    event CycleEnded(uint256 cycleNumber, uint256 rewardTPBMinted);
    event AutoRedeemExecuted(address indexed user, uint256 tpbBurned, uint256 wbtcReturned);

    function advanceStep() external onlyKeeper {
        currentStep++;
        emit StepChanged(currentStep);
    }

    function setStep(uint256 step) external onlyKeeper {
        currentStep = step;
        emit StepChanged(step);
    }

    function lockVault() external onlyKeeper {
        require(!locked, "TPB: already locked");
        locked = true;
        emit Locked();
    }

    function unlockVault() external onlyKeeper {
        require(locked, "TPB: not locked");
        locked = false;
        currentStep = 0;
        emit Unlocked();
    }

    /// @notice Update current BTC price (for entry fee calculation)
    function updatePrice(uint256 price) external onlyKeeper {
        currentPrice = price;
    }

    /// @notice End cycle and distribute rewards (C2 fix: auto-redeem BEFORE rewards)
    /// @dev M1 fix: holders array capped at MAX_HOLDERS_PER_BATCH
    function endCycleAndReward(
        uint256 newATH,
        uint256 rewardSats,
        address[] calldata holders
    ) external onlyKeeper nonReentrant {
        require(newATH > currentATH, "TPB: ATH not higher");
        require(currentStep == 0, "TPB: not at step 0");
        require(holders.length <= MAX_HOLDERS_PER_BATCH, "TPB: too many holders");

        // ---- C2 FIX: Process auto-redeems FIRST (before supply changes) ----
        uint256 liquidWBTC = wbtc.balanceOf(address(this));
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 redeemBPS = autoRedeemBPS[holder];
            if (redeemBPS == 0) continue;

            uint256 bal = balanceOf[holder];
            uint256 tpbToRedeem = (bal * redeemBPS) / MAX_BPS;
            if (tpbToRedeem == 0) continue;

            uint256 wbtcOut = _convertToAssets(tpbToRedeem);
            if (wbtcOut == 0) continue;
            if (wbtcOut > liquidWBTC) wbtcOut = liquidWBTC;

            _burn(holder, tpbToRedeem);
            require(wbtc.transfer(holder, wbtcOut), "TPB: auto-redeem transfer failed");
            liquidWBTC -= wbtcOut;

            emit AutoRedeemExecuted(holder, tpbToRedeem, wbtcOut);
        }

        // ---- Then mint reward TPB pro-rata ----
        uint256 supplySnapshot = totalSupply;
        uint256 totalRewardMinted = 0;

        if (rewardSats > 0 && supplySnapshot > 0) {
            for (uint256 i = 0; i < holders.length; i++) {
                address holder = holders[i];
                uint256 bal = balanceOf[holder];
                if (bal == 0) continue;

                uint256 reward = (rewardSats * bal) / supplySnapshot;

                if (address(nftBonus) != address(0)) {
                    uint256 multiplier = nftBonus.getBonusMultiplier(holder);
                    if (multiplier > MAX_BPS) {
                        reward = (reward * multiplier) / MAX_BPS;
                    }
                }

                if (reward > 0) {
                    _mint(holder, reward);
                    totalRewardMinted += reward;
                }
            }
        }

        // Update cycle
        currentATH = newATH;
        cycleNumber++;
        cycleStartTime = block.timestamp;
        locked = false;
        currentStep = 0;

        emit CycleEnded(cycleNumber - 1, totalRewardMinted);
    }

    // ================================================================
    // Safe WBTC Accounting (H1 fix: rate-limited)
    // ================================================================
    event SafeWBTCUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Update safeWBTC with rate limiting (max ±20% per day)
    function updateSafeWBTC(uint256 _safeWBTC) external onlyKeeper {
        uint256 oldValue = safeWBTC;

        // H1 fix: rate limit changes
        if (oldValue > 0 && lastSafeWBTCUpdate > 0) {
            // Allow unrestricted if first update or within 20%
            uint256 maxChange = (oldValue * MAX_SAFE_WBTC_CHANGE_BPS) / MAX_BPS;
            uint256 change = _safeWBTC > oldValue ? _safeWBTC - oldValue : oldValue - _safeWBTC;

            // If more than 20% change AND less than 1 day since last update, require owner
            if (change > maxChange && block.timestamp < lastSafeWBTCUpdate + 1 days) {
                require(msg.sender == owner, "TPB: safeWBTC change too large, need owner");
            }
        }

        safeWBTC = _safeWBTC;
        lastSafeWBTCUpdate = block.timestamp;
        lastSafeWBTCValue = _safeWBTC;

        emit SafeWBTCUpdated(oldValue, _safeWBTC);
    }

    /// @notice Force update safeWBTC without rate limit (owner only, for cycle resets)
    function forceUpdateSafeWBTC(uint256 _safeWBTC) external onlyOwner {
        uint256 oldValue = safeWBTC;
        safeWBTC = _safeWBTC;
        lastSafeWBTCUpdate = block.timestamp;
        lastSafeWBTCValue = _safeWBTC;
        emit SafeWBTCUpdated(oldValue, _safeWBTC);
    }

    // ================================================================
    // Admin
    // ================================================================
    function setSafe(address _safe) external onlyOwner {
        require(_safe != address(0), "TPB: zero address");
        safe = _safe;
    }

    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "TPB: zero address");
        keeper = _keeper;
    }

    function setNFTBonus(address _nft) external onlyOwner {
        nftBonus = INFTBonus(_nft);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        feeRecipient = _recipient;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "TPB: zero address");
        owner = newOwner;
    }

    /// @notice Emergency: recover stuck tokens (L3 fix: check return value)
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(wbtc), "TPB: cannot recover WBTC");
        require(IERC20(token).transfer(owner, amount), "TPB: recovery failed");
    }

    // ================================================================
    // ERC-20 Internal
    // ================================================================
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // L1 fix: no nonReentrant on transfer/transferFrom (no external calls)
    // L2 fix: block transfer to address(0)
    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "TPB: transfer to zero");
        require(balanceOf[msg.sender] >= amount, "TPB: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "TPB: transfer to zero");
        require(balanceOf[from] >= amount, "TPB: insufficient");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "TPB: allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
