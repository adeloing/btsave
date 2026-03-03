// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategyOnChain } from "./interfaces/IStrategyOnChain.sol";
import { NFTBonus } from "./NFTBonus.sol";

/**
 * @title TurboPaperBoatVault — Full On-Chain Arbitrum (V1)
 * @notice ERC4626 vault holding WBTC. Strategy executes hedges on AAVE + GMX V2.
 *         Entry fee with dynamic rate near ATH, reduced by NFTBonus multiplier.
 *         Pause/unpause with guardian + timelock.
 *         All entry points (deposit/mint/withdraw/redeem) are pause-guarded.
 */
contract TurboPaperBoatVault is ERC4626, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // ======================== ROLES ========================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ======================== STATE ========================
    bool public paused;
    IStrategyOnChain public strategy;
    NFTBonus public nftBonus;
    address public treasury;

    // ======================== ENTRY FEE CONFIG ========================
    uint256 public constant BASE_ENTRY_FEE_BPS = 200;   // 2%
    uint256 public constant ATH_ENTRY_FEE_BPS  = 500;   // 5% when price > 95% ATH
    uint256 public constant ATH_THRESHOLD_BPS  = 9500;   // 95%

    // ======================== EXIT FEE CONFIG ========================
    uint256 public constant EXIT_FEE_7D_BPS   = 200;    // 2.0% if < 7 days
    uint256 public constant EXIT_FEE_30D_BPS  = 100;    // 1.0% if < 30 days
    uint256 public constant EXIT_FEE_90D_BPS  =  50;    // 0.5% if < 90 days
    uint256 public constant CYCLE_BONUS_BPS   = 100;    // +1.0% in drawdown (> -10% ATH)
    uint256 public constant DRAWDOWN_THRESHOLD_BPS = 9000; // 90% ATH = -10% drawdown

    // ======================== EXIT FEE STATE ========================
    mapping(address => uint256) public userDepositTime;

    // ======================== EVENTS ========================
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event ExitFeeCharged(address indexed user, uint256 assets, uint256 feeAmount, uint256 holdingDays, bool inDrawdown);
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event NFTBonusUpdated(address indexed oldNFTBonus, address indexed newNFTBonus);

    // ======================== ERRORS ========================
    error VaultPaused();
    error ZeroAddress();

    // ======================== MODIFIERS ========================
    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    constructor(
        IERC20 asset_,
        IStrategyOnChain strategy_,
        NFTBonus nftBonus_,
        address treasury_,
        address timelock_,
        address guardian_
    ) ERC4626(asset_) ERC20("Turbo Paper Boat", "TPB") {
        if (address(strategy_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        strategy = strategy_;
        nftBonus = nftBonus_;
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);  // admin = timelock (all critical ops)
        _grantRole(GUARDIAN_ROLE, guardian_);         // guardian = founder (instant pause)
    }

    // ======================== EXIT FEE LOGIC ========================

    function getExitFeeBps(address user) public view returns (uint256) {
        uint256 depositTime = userDepositTime[user];
        if (depositTime == 0) return 0;

        uint256 holdingDays = (block.timestamp - depositTime) / 1 days;

        uint256 feeBps;
        if (holdingDays < 7) feeBps = EXIT_FEE_7D_BPS;
        else if (holdingDays < 30) feeBps = EXIT_FEE_30D_BPS;
        else if (holdingDays < 90) feeBps = EXIT_FEE_90D_BPS;
        else return 0; // >= 90 days: no fee at all

        uint256 ath = strategy.currentATH();
        uint256 price = strategy.currentPrice();
        if (ath > 0 && price < (ath * DRAWDOWN_THRESHOLD_BPS) / 10_000) {
            feeBps += CYCLE_BONUS_BPS;
        }

        return feeBps;
    }

    // ======================== ENTRY FEE LOGIC ========================

    /// @dev Base fee: 5% near ATH, 2% otherwise
    function _baseFeeBps() internal view returns (uint256) {
        uint256 ath = strategy.currentATH();
        uint256 price = strategy.currentPrice();
        if (ath > 0 && price > (ath * ATH_THRESHOLD_BPS) / 10_000) {
            return ATH_ENTRY_FEE_BPS;
        }
        return BASE_ENTRY_FEE_BPS;
    }

    /// @dev Effective fee for a user, reduced by NFTBonus multiplier.
    ///      multiplier=10000 (no NFTs) → full fee
    ///      multiplier=12000 (1.2x)    → fee * 10000/12000 = ~83% of base fee
    ///      multiplier=22750 (max)      → fee * 10000/22750 = ~44% of base fee
    ///      Fee never goes below 50 bps (0.5%) minimum.
    function _effectiveFeeBps(address user) internal view returns (uint256) {
        uint256 baseFee = _baseFeeBps();
        if (address(nftBonus) == address(0)) return baseFee;

        uint256 multiplier = nftBonus.getBonusMultiplier(user);
        if (multiplier <= 10_000) return baseFee; // no bonus

        uint256 discountedFee = (baseFee * 10_000) / multiplier;
        uint256 minFee = 50; // 0.5% floor
        return discountedFee > minFee ? discountedFee : minFee;
    }

    /// @notice Preview shares received for a deposit amount (fee deducted)
    /// @dev Uses msg.sender for NFT bonus lookup in previews
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = (assets * _effectiveFeeBps(msg.sender)) / 10_000;
        return super.previewDeposit(assets - fee);
    }

    /// @notice Preview assets required to mint exact shares (fee added)
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        uint256 feeBps = _effectiveFeeBps(msg.sender);
        return assets + (assets * feeBps) / (10_000 - feeBps) + 1; // round up
    }

    /// @dev Override internal deposit: deduct fee (NFT-discounted), send to treasury, net to strategy
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 fee = (assets * _effectiveFeeBps(receiver)) / 10_000;
        uint256 net = assets - fee;

        // Pull total from caller
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);

        // Fee → treasury
        if (fee > 0) {
            IERC20(asset()).safeTransfer(treasury, fee);
        }

        // Net → strategy (supply to AAVE)
        IERC20(asset()).safeIncreaseAllowance(address(strategy), net);
        strategy.deposit(net);

        // Track deposit time (reset on each deposit — simple, no per-tranche tracking)
        userDepositTime[receiver] = block.timestamp;

        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Override internal withdraw: pull from strategy, apply exit fee
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);

        // Pull full amount from strategy to vault
        uint256 received = strategy.withdraw(assets, address(this));

        // Apply exit fee
        uint256 feeBps = getExitFeeBps(owner);
        uint256 feeAmount;
        if (feeBps > 0) {
            feeAmount = (received * feeBps) / 10_000;
            received -= feeAmount;
            IERC20(asset()).safeTransfer(treasury, feeAmount);

            uint256 ath = strategy.currentATH();
            uint256 price = strategy.currentPrice();
            bool inDrawdown = ath > 0 && price < (ath * DRAWDOWN_THRESHOLD_BPS) / 10_000;
            uint256 holdingDays = (block.timestamp - userDepositTime[owner]) / 1 days;
            emit ExitFeeCharged(owner, received, feeAmount, holdingDays, inDrawdown);
        }

        IERC20(asset()).safeTransfer(receiver, received);
        emit Withdraw(caller, receiver, owner, received, shares);
    }

    // ======================== PAUSE-GUARDED ENTRY POINTS ========================

    function deposit(uint256 assets, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // ======================== PAUSE ========================

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ======================== ADMIN (TIMELOCKED) ========================

    function setStrategy(IStrategyOnChain newStrategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newStrategy) == address(0)) revert ZeroAddress();
        emit StrategyUpdated(address(strategy), address(newStrategy));
        strategy = newStrategy;
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setNFTBonus(NFTBonus newNFTBonus) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit NFTBonusUpdated(address(nftBonus), address(newNFTBonus));
        nftBonus = newNFTBonus; // address(0) allowed = disables bonus
    }

    // ======================== C1: EXIT FEE BYPASS PREVENTION ========================

    /// @dev Reset deposit timer on transfers to prevent exit fee bypass
    function _update(address from, address to, uint256 value) internal override(ERC20) {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && value > 0) {
            userDepositTime[to] = block.timestamp;
        }
    }

    // ======================== C14: EMERGENCY WITHDRAW ========================

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function emergencyWithdrawFromStrategy(uint256 assets, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        strategy.withdraw(assets, to);
    }

    // ======================== VIEW ========================

    function totalAssets() public view override returns (uint256) {
        return strategy.totalAssets();
    }
}
