// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IInterfaces.sol";

/**
 * @title StrategyHybridAccumulator
 * @notice Manages the hybrid accumulation strategy across Aave and Deribit
 * @dev UUPS upgradeable contract that orchestrates cycle resets and position management
 */
contract StrategyHybridAccumulator is
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Allocation constants (in basis points)
    uint256 public constant WBTC_AAVE_ALLOCATION_BPS = 8200; // 82%
    uint256 public constant USDC_AAVE_ALLOCATION_BPS = 1500; // 15%
    uint256 public constant USDC_DERIBIT_ALLOCATION_BPS = 300; // 3%
    uint256 public constant BPS_DENOMINATOR = 10000;

    /* ========== STATE VARIABLES ========== */

    /// @notice Associated vault contract
    ITurboPaperBoatVault public vault;
    
    /// @notice NFT rewards contract
    INFTCycleRewards public nftRewards;

    /// @notice Current cycle number
    uint256 public cycleCount;
    
    /// @notice Whether a cycle is currently active
    bool public cycleActive;
    
    /// @notice Timestamp of last cycle reset
    uint256 public lastCycleReset;
    
    /// @notice Off-chain reported USDC balance from Deribit
    uint256 public deribitReportedBalance;

    /// @notice Snapshot of eligible NFT recipients (simplified for demo)
    mapping(address => uint256) public lastCycleSnapshots;
    
    /// @notice Array of addresses that participated in last cycle
    address[] public lastCycleParticipants;

    /* ========== EVENTS ========== */

    event CycleReset(uint256 indexed cycleCount, uint256 newATH);
    event DeribitBalanceReported(uint256 usdcBalance);
    event CycleStatusChanged(bool active);
    event NFTMintTriggered(address indexed user, uint256 balance, uint256 requestId);
    event AllocationTargetsUpdated();

    /* ========== ERRORS ========== */

    error CycleNotActive();
    error CycleAlreadyActive();
    error InvalidVaultAddress();
    error InvalidNFTAddress();
    error UnauthorizedCaller();

    /* ========== INITIALIZER ========== */

    /**
     * @notice Initialize the strategy contract
     * @param _vault Vault contract address
     * @param _nftRewards NFT rewards contract address
     */
    function initialize(
        address _vault,
        address _nftRewards
    ) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        if (_nftRewards == address(0)) revert InvalidNFTAddress();

        if (_vault != address(0)) {
            vault = ITurboPaperBoatVault(_vault);
        }
        nftRewards = INFTCycleRewards(_nftRewards);
        
        cycleCount = 0;
        cycleActive = true;
        lastCycleReset = block.timestamp;
    }

    /* ========== CYCLE MANAGEMENT ========== */

    /**
     * @notice Reset cycle after new ATH is reached
     * @dev Only callable by OPERATOR_ROLE. This is the core cycle reset logic.
     */
    function resetCycle() external onlyRole(OPERATOR_ROLE) {
        // Set cycle as inactive during reset process
        cycleActive = false;
        emit CycleStatusChanged(false);

        // Step 1: Harvest fees from vault before reset
        vault.harvest();

        // Step 2: Close all Deribit short positions (stub implementation)
        _closeDeribitShorts();

        // Step 3: Repay 100% of Aave debt (stub implementation)
        _repayAaveDebt();

        // Step 4: Sell minimal WBTC to cover any remaining debt (stub implementation)
        _rebalancePositions();

        // Step 5: Trigger NFT mints for eligible holders
        _triggerNFTMints();

        // Step 6: Increment cycle count and reactivate
        cycleCount++;
        cycleActive = true;
        lastCycleReset = block.timestamp;

        emit CycleReset(cycleCount, 0); // ATH value would come from oracle
        emit CycleStatusChanged(true);
    }

    /**
     * @notice Report Deribit balance from off-chain systems
     * @dev Only callable by OPERATOR_ROLE
     * @param usdcBalance Current USDC balance in Deribit positions
     */
    function reportDeribitBalance(uint256 usdcBalance) external onlyRole(OPERATOR_ROLE) {
        deribitReportedBalance = usdcBalance;
        
        // Update vault with new balance
        vault.updateDeribitBalance(usdcBalance);
        
        emit DeribitBalanceReported(usdcBalance);
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get current cycle information
     * @return cycle Current cycle number
     * @return active Whether cycle is active
     * @return lastReset Timestamp of last reset
     */
    function currentCycle() 
        external 
        view 
        returns (
            uint256 cycle,
            bool active,
            uint256 lastReset
        )
    {
        return (cycleCount, cycleActive, lastCycleReset);
    }

    /**
     * @notice Get allocation targets
     * @return wbtcAave WBTC allocation to Aave (BPS)
     * @return usdcAave USDC allocation to Aave (BPS)  
     * @return usdcDeribit USDC allocation to Deribit (BPS)
     */
    function getAllocationTargets()
        external
        pure
        returns (
            uint256 wbtcAave,
            uint256 usdcAave,
            uint256 usdcDeribit
        )
    {
        return (
            WBTC_AAVE_ALLOCATION_BPS,
            USDC_AAVE_ALLOCATION_BPS,
            USDC_DERIBIT_ALLOCATION_BPS
        );
    }

    /**
     * @notice Get Deribit reported balance
     * @return Current off-chain USDC balance
     */
    function getDeribitBalance() external view returns (uint256) {
        return deribitReportedBalance;
    }

    /**
     * @notice Get last cycle participants
     * @return Array of participant addresses
     */
    function getLastCycleParticipants() external view returns (address[] memory) {
        return lastCycleParticipants;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Update vault contract address
     * @param _vault New vault address
     */
    function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert InvalidVaultAddress();
        vault = ITurboPaperBoatVault(_vault);
    }

    /**
     * @notice Update NFT rewards contract address
     * @param _nftRewards New NFT rewards address
     */
    function setNFTRewards(address _nftRewards) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_nftRewards == address(0)) revert InvalidNFTAddress();
        nftRewards = INFTCycleRewards(_nftRewards);
    }

    /**
     * @notice Emergency cycle activation toggle
     * @dev For emergency use only
     * @param _active New cycle status
     */
    function setCycleActive(bool _active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        cycleActive = _active;
        emit CycleStatusChanged(_active);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice Close all Deribit short positions
     * @dev Stub implementation - would integrate with Deribit API
     */
    function _closeDeribitShorts() internal {
        // TODO: Implement Deribit integration
        // - Close all open short positions
        // - Settle any pending trades
        // - Calculate final P&L
        
        // For now, just reset the reported balance to 0
        deribitReportedBalance = 0;
        vault.updateDeribitBalance(0);
    }

    /**
     * @notice Repay 100% of Aave debt
     * @dev Stub implementation - would integrate with Aave protocol
     */
    function _repayAaveDebt() internal {
        // TODO: Implement Aave integration
        // - Query current debt positions
        // - Repay all USDC debt
        // - Repay all WBTC debt
        // - Withdraw excess collateral if any
    }

    /**
     * @notice Rebalance positions to target allocations
     * @dev Stub implementation - would execute trades to reach 82/15/3 split
     */
    function _rebalancePositions() internal {
        // TODO: Implement rebalancing logic
        // - Calculate current total value
        // - Determine target amounts for each position
        // - Execute necessary trades/swaps
        // - Deploy capital to Aave (82% WBTC, 15% USDC)
        // - Deploy capital to Deribit (3% USDC)
        
        emit AllocationTargetsUpdated();
    }

    /**
     * @notice Trigger NFT mints for eligible holders
     * @dev Simplified implementation - in production would snapshot vault holders
     */
    function _triggerNFTMints() internal {
        // TODO: Implement proper snapshotting logic
        // - Take snapshot of all vault shareholders
        // - Calculate average balances over the cycle
        // - Request NFT mints for eligible users (>= 100 USDC avg)
        
        // Stub: Clear previous participants and emit event
        delete lastCycleParticipants;
        
        // In a real implementation, this would iterate through vault shareholders
        // and call nftRewards.requestMint(user, avgBalance) for eligible users
    }

    /**
     * @notice Manual NFT mint trigger for specific user (admin function)
     * @dev Used for testing or manual intervention
     * @param user User address
     * @param avgBalance Average balance over cycle
     */
    function triggerNFTMintManual(address user, uint256 avgBalance) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 requestId = nftRewards.requestMint(user, avgBalance);
        lastCycleSnapshots[user] = avgBalance;
        
        emit NFTMintTriggered(user, avgBalance, requestId);
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
}