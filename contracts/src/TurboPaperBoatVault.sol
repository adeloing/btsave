// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IInterfaces.sol";

/**
 * @title TurboPaperBoatVault
 * @notice ERC-4626 compliant vault that tracks WBTC + USDC positions across Aave and Deribit
 * @dev UUPS upgradeable vault with role-based access control and emergency timelock
 */
contract TurboPaperBoatVault is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ========== */

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");

    uint256 public constant MANAGEMENT_FEE_BPS = 100; // 1% annual
    uint256 public constant PERFORMANCE_FEE_BPS = 1500; // 15%
    uint256 public constant NFT_REWARD_SHARE_BPS = 4000; // 40% of performance fee to NFT rewards
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    // Manual reentrancy guard
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /* ========== STATE VARIABLES ========== */

    /// @notice Oracle manager contract for price feeds and redemption windows
    IOracleManager public oracleManager;
    
    /// @notice Strategy contract for managing positions
    IStrategyHybridAccumulator public strategy;
    
    /// @notice Treasury address for management fees
    address public treasury;
    
    /// @notice NFT reward pool address for performance fee share
    address public nftRewardPool;

    /// @notice WBTC token contract
    IERC20Decimals public wbtcToken;
    
    /// @notice Aave WBTC aToken
    IERC20Decimals public aWBTC;
    
    /// @notice Aave USDC aToken  
    IERC20Decimals public aUSDC;

    /// @notice Last harvest timestamp for management fee calculation
    uint256 public lastHarvest;
    
    /// @notice High water mark for performance fee calculation
    uint256 public highWaterMark;
    
    /// @notice Off-chain reported balance from Deribit positions
    uint256 public deribitReportedBalance;

    /// @notice Scheduled emergency withdrawals with timelock
    mapping(bytes32 => EmergencyWithdrawal) public emergencyWithdrawals;

    /// @notice Reentrancy guard status
    uint256 private _status;

    struct EmergencyWithdrawal {
        address token;
        uint256 amount;
        address recipient;
        uint256 executeAfter;
        bool executed;
    }

    /* ========== EVENTS ========== */

    event CycleReset(uint256 indexed cycleCount, uint256 newATH);
    event PerformanceFeeCollected(uint256 shares, uint256 treasuryShares, uint256 nftRewardShares);
    event ManagementFeeCollected(uint256 shares);
    event EmergencyWithdrawScheduled(bytes32 indexed id, address token, uint256 amount, uint256 executeAfter);
    event EmergencyWithdrawExecuted(bytes32 indexed id, address token, uint256 amount);
    event DeribitBalanceUpdated(uint256 newBalance);

    /* ========== ERRORS ========== */

    error RedemptionWindowClosed();
    error EmergencyWithdrawTooEarly();
    error EmergencyWithdrawAlreadyExecuted();
    error EmergencyWithdrawNotFound();
    error InvalidAddress();
    error InvalidAmount();
    error ReentrantCall();

    /* ========== MODIFIERS ========== */

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        if (_status == ENTERED) {
            revert ReentrantCall();
        }
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    /* ========== INITIALIZER ========== */

    /**
     * @notice Initialize the vault
     * @param _asset USDC token address (6 decimals)
     * @param _name Vault name
     * @param _symbol Vault symbol
     * @param _oracleManager Oracle manager contract
     * @param _strategy Strategy contract
     * @param _treasury Treasury address
     * @param _nftRewardPool NFT reward pool address
     * @param _wbtcToken WBTC token address
     * @param _aWBTC Aave WBTC aToken address
     * @param _aUSDC Aave USDC aToken address
     */
    function initialize(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _oracleManager,
        address _strategy,
        address _treasury,
        address _nftRewardPool,
        address _wbtcToken,
        address _aWBTC,
        address _aUSDC
    ) external initializer {
        __ERC4626_init(_asset);
        __ERC20_init(_name, _symbol);
        __AccessControl_init();
        __Pausable_init();
        
        _status = NOT_ENTERED;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(STRATEGIST_ROLE, msg.sender);

        oracleManager = IOracleManager(_oracleManager);
        strategy = IStrategyHybridAccumulator(_strategy);
        treasury = _treasury;
        nftRewardPool = _nftRewardPool;
        wbtcToken = IERC20Decimals(_wbtcToken);
        aWBTC = IERC20Decimals(_aWBTC);
        aUSDC = IERC20Decimals(_aUSDC);
        
        lastHarvest = block.timestamp;
        highWaterMark = 1e6; // Start at 1 USDC per share
    }

    /* ========== ERC-4626 OVERRIDES ========== */

    /**
     * @notice Calculate total assets under management
     * @dev Queries aToken balances (WBTC converted via oracle) + USDC + Deribit balance + vault cash
     * @return Total assets in USDC (6 decimals)
     */
    function totalAssets() public view override returns (uint256) {
        // Get vault cash balance
        uint256 vaultCash = IERC20(asset()).balanceOf(address(this));
        
        // Get Aave USDC balance
        uint256 aaveUSDC = aUSDC.balanceOf(address(this));
        
        // Get Aave WBTC balance converted to USDC
        uint256 aaveWBTC = aWBTC.balanceOf(address(this));
        uint256 btcPrice = oracleManager.getSpotPrice(); // 18 decimals
        
        // Convert WBTC (8 decimals) to USDC (6 decimals) using BTC price (18 decimals)
        // aaveWBTC * btcPrice / 1e18 / 1e2 (to convert from 8+18-18-2 = 6 decimals)
        uint256 aaveWBTCInUSDC = (aaveWBTC * btcPrice) / 1e20;
        
        // Add Deribit reported balance
        return vaultCash + aaveUSDC + aaveWBTCInUSDC + deribitReportedBalance;
    }

    /**
     * @notice Deposit assets and receive vault shares
     * @param assets Amount of USDC to deposit
     * @param receiver Address to receive shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint specific amount of shares
     * @param shares Amount of shares to mint
     * @param receiver Address to receive shares
     * @return assets Amount of assets required
     */
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        return super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw assets by burning shares
     * @dev Only allowed when redemption window is open
     * @param assets Amount of USDC to withdraw
     * @param receiver Address to receive assets
     * @param owner Address owning the shares
     * @return shares Amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        if (!oracleManager.isRedemptionWindowOpen()) {
            revert RedemptionWindowClosed();
        }
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares for assets
     * @dev Only allowed when redemption window is open
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive assets
     * @param owner Address owning the shares
     * @return assets Amount of assets withdrawn
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        if (!oracleManager.isRedemptionWindowOpen()) {
            revert RedemptionWindowClosed();
        }
        return super.redeem(shares, receiver, owner);
    }

    /* ========== VAULT MANAGEMENT ========== */

    /**
     * @notice Harvest management and performance fees
     * @dev Only callable by OPERATOR_ROLE
     */
    function harvest() external onlyRole(OPERATOR_ROLE) {
        uint256 currentTime = block.timestamp;
        uint256 totalSupply_ = totalSupply();
        
        if (totalSupply_ == 0) {
            lastHarvest = currentTime;
            return;
        }

        // Calculate and mint management fee (1% annual)
        uint256 timeElapsed = currentTime - lastHarvest;
        uint256 managementFeeShares = (totalSupply_ * MANAGEMENT_FEE_BPS * timeElapsed) / 
            (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        
        if (managementFeeShares > 0) {
            _mint(treasury, managementFeeShares);
            emit ManagementFeeCollected(managementFeeShares);
        }

        // Calculate and mint performance fee (15% on profits above high water mark)
        uint256 currentPricePerShare = totalAssets() * 1e18 / (totalSupply_ + managementFeeShares);
        
        if (currentPricePerShare > highWaterMark) {
            uint256 profit = currentPricePerShare - highWaterMark;
            uint256 performanceFeeShares = (totalSupply_ * profit * PERFORMANCE_FEE_BPS) / 
                (1e18 * BPS_DENOMINATOR);
            
            if (performanceFeeShares > 0) {
                // 60% to treasury, 40% to NFT reward pool
                uint256 nftRewardShares = (performanceFeeShares * NFT_REWARD_SHARE_BPS) / BPS_DENOMINATOR;
                uint256 treasuryShares = performanceFeeShares - nftRewardShares;
                
                _mint(treasury, treasuryShares);
                _mint(nftRewardPool, nftRewardShares);
                
                highWaterMark = currentPricePerShare;
                emit PerformanceFeeCollected(performanceFeeShares, treasuryShares, nftRewardShares);
            }
        }

        lastHarvest = currentTime;
    }

    /**
     * @notice Update Deribit reported balance
     * @dev Called by strategy contract to report off-chain positions
     * @param usdcBalance New USDC balance from Deribit
     */
    function updateDeribitBalance(uint256 usdcBalance) external onlyRole(OPERATOR_ROLE) {
        deribitReportedBalance = usdcBalance;
        emit DeribitBalanceUpdated(usdcBalance);
    }

    /* ========== EMERGENCY FUNCTIONS ========== */

    /**
     * @notice Schedule emergency withdrawal with timelock
     * @dev Only callable by DEFAULT_ADMIN_ROLE, subject to 24h delay
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     * @param recipient Address to receive tokens
     */
    function scheduleEmergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        bytes32 id = keccak256(abi.encodePacked(token, amount, recipient, block.timestamp));
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        
        emergencyWithdrawals[id] = EmergencyWithdrawal({
            token: token,
            amount: amount,
            recipient: recipient,
            executeAfter: executeAfter,
            executed: false
        });

        emit EmergencyWithdrawScheduled(id, token, amount, executeAfter);
    }

    /**
     * @notice Execute scheduled emergency withdrawal
     * @dev Bypasses pause state, executable after timelock delay
     * @param id Withdrawal ID to execute
     */
    function executeEmergencyWithdraw(bytes32 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EmergencyWithdrawal storage withdrawal = emergencyWithdrawals[id];
        
        if (withdrawal.token == address(0)) revert EmergencyWithdrawNotFound();
        if (withdrawal.executed) revert EmergencyWithdrawAlreadyExecuted();
        if (block.timestamp < withdrawal.executeAfter) revert EmergencyWithdrawTooEarly();

        withdrawal.executed = true;
        
        IERC20(withdrawal.token).safeTransfer(
            withdrawal.recipient,
            withdrawal.amount
        );

        emit EmergencyWithdrawExecuted(id, withdrawal.token, withdrawal.amount);
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Pause the vault
     * @dev Prevents new deposits and mints
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the vault
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Update oracle manager
     */
    function setOracleManager(address _oracleManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oracleManager == address(0)) revert InvalidAddress();
        oracleManager = IOracleManager(_oracleManager);
    }

    /**
     * @notice Update strategy contract
     */
    function setStrategy(address _strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_strategy == address(0)) revert InvalidAddress();
        strategy = IStrategyHybridAccumulator(_strategy);
    }

    /**
     * @notice Update treasury address
     */
    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    /**
     * @notice Update NFT reward pool address
     */
    function setNftRewardPool(address _nftRewardPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_nftRewardPool == address(0)) revert InvalidAddress();
        nftRewardPool = _nftRewardPool;
    }

    /* ========== UPGRADE AUTHORIZATION ========== */

    /**
     * @notice Authorize contract upgrade
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {}

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get current price per share
     * @return Price per share in 18 decimals
     */
    function pricePerShare() external view returns (uint256) {
        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) return 1e18;
        return (totalAssets() * 1e18) / totalSupply_;
    }
}