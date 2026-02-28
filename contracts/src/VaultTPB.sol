// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VaultTPB v2 — Turbo Paper Boat Vault
 * @notice Simplified BTC accumulation vault with transferable TPB token.
 *
 *  Flow:
 *   1. User deposits WBTC → receives TPB (1 WBTC = 1e8 TPB, satoshi-pegged)
 *   2. WBTC sits in pending pool until weekly rebalance deploys it into strategy
 *   3. TPB is freely transferable / tradable on DEX
 *   4. At cycle end (new ATH ratcheté): bonus TPB minted pro-rata to holders
 *   5. Redemption: burn TPB → WBTC, only at step 0 (post-ATH, pre-lock)
 *   6. Auto-redeem: user sets % to auto-redeem at next ATH reset
 *   7. NFT bonus multiplier on reward mint
 *
 *  Cycle: ATH → ATH (ratcheté). Lock at ATH - 5%.
 */

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface INFTBonus {
    function getBonusMultiplier(address user) external view returns (uint256);
}

contract VaultTPB {
    // ================================================================
    // ERC-20: TPB Token (inline, no inheritance needed)
    // ================================================================
    string public constant name = "Turbo Paper Boat";
    string public constant symbol = "TPB";
    uint8 public constant decimals = 8; // same as WBTC

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ================================================================
    // Vault State
    // ================================================================
    IERC20 public immutable wbtc;
    address public safe;           // Gnosis Safe (strategy executor)
    address public keeper;         // Bot / keeper for rebalance & cycle ops
    INFTBonus public nftBonus;     // Optional NFT bonus contract

    // Cycle
    uint256 public currentATH;           // in USD (8 decimals like Chainlink)
    uint256 public cycleStartTime;
    uint256 public cycleNumber;
    uint256 public currentStep;          // 0 = post-ATH, increments on drops
    bool public locked;                  // true when price hits ATH - 5%
    uint256 public constant LOCK_THRESHOLD_BPS = 500; // 5%

    // Pending pool
    uint256 public pendingWBTC;          // WBTC awaiting rebalance
    uint256 public constant REBALANCE_THRESHOLD_BPS = 200; // 2% of deployed TVL
    uint256 public lastRebalanceTime;

    // Auto-redeem
    mapping(address => uint256) public autoRedeemBPS; // 0-10000
    uint256 public constant MAX_BPS = 10_000;

    // Reentrancy guard
    bool private _locked;

    // ================================================================
    // Access Control
    // ================================================================
    address public owner; // 2/2 Safe for admin ops

    modifier onlyOwner() {
        require(msg.sender == owner, "TPB: not owner");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner, "TPB: not keeper");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "TPB: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    // ================================================================
    // Constructor
    // ================================================================
    constructor(
        address _wbtc,
        address _safe,
        address _keeper,
        uint256 _initialATH // e.g. 126000e8 for $126,000
    ) {
        wbtc = IERC20(_wbtc);
        safe = _safe;
        keeper = _keeper;
        owner = msg.sender;
        currentATH = _initialATH;
        cycleStartTime = block.timestamp;
        cycleNumber = 1;
        currentStep = 0;
        locked = false;
        lastRebalanceTime = block.timestamp;
    }

    // ================================================================
    // Deposit: WBTC → TPB (NAV-based)
    // ================================================================
    event Deposited(address indexed user, uint256 wbtcAmount, uint256 tpbMinted);

    /// @notice Total WBTC controlled by the vault (in vault + in Safe strategy)
    /// @dev Safe WBTC tracked via `safeWBTC`, updated by keeper after rebalance
    uint256 public safeWBTC; // WBTC deployed in Safe (strategy)

    function totalAssets() public view returns (uint256) {
        return wbtc.balanceOf(address(this)) + safeWBTC;
    }

    function deposit(uint256 wbtcAmount) external nonReentrant {
        require(wbtcAmount > 0, "TPB: zero deposit");

        // Calculate shares BEFORE transfer (like ERC-4626)
        uint256 shares;
        uint256 supply = totalSupply;
        uint256 assets = totalAssets();
        if (supply == 0 || assets == 0) {
            shares = wbtcAmount; // First deposit: 1:1
        } else {
            shares = (wbtcAmount * supply) / assets;
        }
        require(shares > 0, "TPB: zero shares");

        // Transfer WBTC to vault
        require(wbtc.transferFrom(msg.sender, address(this), wbtcAmount), "TPB: transfer failed");

        // Add to pending pool
        pendingWBTC += wbtcAmount;

        // Mint TPB
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, wbtcAmount, shares);
    }

    // ================================================================
    // Redeem: TPB → WBTC (only step 0, unlocked)
    // ================================================================
    event Redeemed(address indexed user, uint256 tpbBurned, uint256 wbtcReturned);

    /// @notice Preview how much WBTC a given TPB amount would redeem for
    function previewRedeem(uint256 tpbAmount) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (tpbAmount * totalAssets()) / totalSupply;
    }

    function redeem(uint256 tpbAmount) external nonReentrant {
        require(tpbAmount > 0, "TPB: zero redeem");
        require(currentStep == 0, "TPB: not at step 0");
        require(!locked, "TPB: locked");
        require(balanceOf[msg.sender] >= tpbAmount, "TPB: insufficient balance");

        // Calculate WBTC to return: pro-rata of total assets
        uint256 wbtcOut = previewRedeem(tpbAmount);
        require(wbtcOut > 0, "TPB: zero output");

        // Only redeem from vault's liquid WBTC (not from Safe)
        uint256 liquid = wbtc.balanceOf(address(this));
        require(wbtcOut <= liquid, "TPB: insufficient liquidity");

        // Burn TPB
        _burn(msg.sender, tpbAmount);

        // Transfer WBTC
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
    // Pending Pool Rebalance (weekly or threshold)
    // ================================================================
    event Rebalanced(uint256 wbtcDeployed);

    function rebalancePendingPool() external onlyKeeper nonReentrant {
        require(pendingWBTC > 0, "TPB: nothing pending");

        uint256 deployedTVL = wbtc.balanceOf(address(this)) - pendingWBTC;
        bool thresholdMet = deployedTVL > 0 &&
            (pendingWBTC * MAX_BPS) / deployedTVL >= REBALANCE_THRESHOLD_BPS;
        bool weeklyDue = block.timestamp >= lastRebalanceTime + 7 days;

        require(thresholdMet || weeklyDue, "TPB: rebalance not due");

        uint256 amount = pendingWBTC;
        pendingWBTC = 0;
        lastRebalanceTime = block.timestamp;

        // Transfer WBTC to Safe for strategy deployment
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

    /// @notice Move to next step (price dropped another step_size)
    function advanceStep() external onlyKeeper {
        currentStep++;
        emit StepChanged(currentStep);
    }

    /// @notice Set step back (price recovered)
    function setStep(uint256 step) external onlyKeeper {
        currentStep = step;
        emit StepChanged(step);
    }

    /// @notice Lock redemptions (price hit ATH - 5%)
    function lockVault() external onlyKeeper {
        require(!locked, "TPB: already locked");
        locked = true;
        emit Locked();
    }

    /// @notice Unlock redemptions (back at step 0 post-ATH)
    function unlockVault() external onlyKeeper {
        require(locked, "TPB: not locked");
        locked = false;
        currentStep = 0;
        emit Unlocked();
    }

    /// @notice End cycle and distribute rewards
    /// @param newATH New ATH price (must be > current)
    /// @param rewardSats Total reward in satoshis to mint as bonus TPB
    /// @param holders Array of holder addresses to process auto-redeem
    function endCycleAndReward(
        uint256 newATH,
        uint256 rewardSats,
        address[] calldata holders
    ) external onlyKeeper nonReentrant {
        require(newATH > currentATH, "TPB: ATH not higher");
        require(currentStep == 0, "TPB: not at step 0");

        uint256 supplySnapshot = totalSupply;
        uint256 totalRewardMinted = 0;

        // Mint reward TPB pro-rata to all holders
        if (rewardSats > 0 && supplySnapshot > 0) {
            for (uint256 i = 0; i < holders.length; i++) {
                address holder = holders[i];
                uint256 bal = balanceOf[holder];
                if (bal == 0) continue;

                // Base reward: pro-rata
                uint256 reward = (rewardSats * bal) / supplySnapshot;

                // NFT bonus multiplier (10000 = 1x, 12000 = 1.2x)
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

        // Process auto-redeems (from liquid WBTC only)
        uint256 liquidWBTC = wbtc.balanceOf(address(this));
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 redeemBPS = autoRedeemBPS[holder];
            if (redeemBPS == 0) continue;

            uint256 bal = balanceOf[holder];
            uint256 tpbToRedeem = (bal * redeemBPS) / MAX_BPS;
            if (tpbToRedeem == 0) continue;

            // Pro-rata of total assets
            uint256 wbtcOut = (tpbToRedeem * totalAssets()) / totalSupply;
            if (wbtcOut == 0) continue;
            if (wbtcOut > liquidWBTC) wbtcOut = liquidWBTC;

            _burn(holder, tpbToRedeem);
            require(wbtc.transfer(holder, wbtcOut), "TPB: auto-redeem transfer failed");
            liquidWBTC -= wbtcOut;

            emit AutoRedeemExecuted(holder, tpbToRedeem, wbtcOut);
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
    // Admin
    // ================================================================
    /// @notice Update safeWBTC to reflect strategy gains/losses
    function updateSafeWBTC(uint256 _safeWBTC) external onlyKeeper {
        safeWBTC = _safeWBTC;
    }

    /// @notice Safe returns WBTC to vault (e.g. at cycle end)
    function returnFromSafe(uint256 amount) external onlyKeeper nonReentrant {
        require(safeWBTC >= amount, "TPB: exceeds safe balance");
        safeWBTC -= amount;
        // Actual WBTC transfer happens via Safe tx, this just updates accounting
    }

    function setSafe(address _safe) external onlyOwner {
        safe = _safe;
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    function setNFTBonus(address _nft) external onlyOwner {
        nftBonus = INFTBonus(_nft);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "TPB: zero address");
        owner = newOwner;
    }

    /// @notice Emergency: recover stuck tokens (not WBTC)
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(wbtc), "TPB: cannot recover WBTC");
        IERC20(token).transfer(owner, amount);
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

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
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

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
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
