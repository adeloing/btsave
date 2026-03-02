// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategyOnChain } from "./interfaces/IStrategyOnChain.sol";

/**
 * @title TurboPaperBoatVault — Full On-Chain Arbitrum (V1)
 * @notice ERC4626 vault holding WBTC. Strategy executes hedges on AAVE + GMX V2.
 *         Entry fee with dynamic rate near ATH. Pause/unpause with guardian + timelock.
 *         All entry points (deposit/mint/withdraw/redeem) are pause-guarded.
 */
contract TurboPaperBoatVault is ERC4626, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // ======================== ROLES ========================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ======================== STATE ========================
    bool public paused;
    IStrategyOnChain public strategy;
    address public treasury;

    // ======================== FEE CONFIG ========================
    uint256 public constant BASE_ENTRY_FEE_BPS = 200;   // 2%
    uint256 public constant ATH_ENTRY_FEE_BPS  = 500;   // 5% when price > 95% ATH
    uint256 public constant ATH_THRESHOLD_BPS  = 9500;   // 95%

    // ======================== EVENTS ========================
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

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
        address treasury_,
        address timelock_,
        address guardian_
    ) ERC4626(asset_) ERC20("Turbo Paper Boat", "TPB") {
        if (address(strategy_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        strategy = strategy_;
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);  // admin = timelock (all critical ops)
        _grantRole(GUARDIAN_ROLE, guardian_);         // guardian = founder (instant pause)
    }

    // ======================== FEE LOGIC ========================

    /// @dev Dynamic fee: 5% near ATH, 2% otherwise
    function _currentFeeBps() internal view returns (uint256) {
        uint256 ath = strategy.currentATH();
        uint256 price = strategy.currentPrice();
        if (ath > 0 && price > (ath * ATH_THRESHOLD_BPS) / 10_000) {
            return ATH_ENTRY_FEE_BPS;
        }
        return BASE_ENTRY_FEE_BPS;
    }

    /// @notice Preview shares received for a deposit amount (fee deducted)
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = (assets * _currentFeeBps()) / 10_000;
        return super.previewDeposit(assets - fee);
    }

    /// @notice Preview assets required to mint exact shares (fee added)
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        uint256 feeBps = _currentFeeBps();
        return assets + (assets * feeBps) / (10_000 - feeBps) + 1; // round up
    }

    /// @dev Override internal deposit: deduct fee, send to treasury, net to strategy
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 fee = (assets * _currentFeeBps()) / 10_000;
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

        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Override internal withdraw: pull from strategy
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

        uint256 received = strategy.withdraw(assets, receiver);
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

    // ======================== VIEW ========================

    function totalAssets() public view override returns (uint256) {
        return strategy.totalAssets();
    }
}
