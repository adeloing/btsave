// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IInterfaces.sol";

// Chainlink interfaces - defined directly since we didn't install the full package
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(
        uint80 _roundId
    ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title OracleManager
 * @notice Manages BTC price feeds and determines redemption windows based on ATH cycles
 * @dev UUPS upgradeable contract with Chainlink integration for BTC/USD price feeds
 */
contract OracleManager is
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    
    uint256 public constant PRICE_STALENESS_THRESHOLD = 1 hours;
    uint256 public constant REDEMPTION_BAND_BPS = 500; // 5% below ATH = 95% of ATH
    uint256 public constant BPS_DENOMINATOR = 10000;

    /* ========== STATE VARIABLES ========== */

    /// @notice Chainlink BTC/USD price feed
    AggregatorV3Interface public btcUsdFeed;
    
    /// @notice Strategy contract to notify on cycle resets
    IStrategyHybridAccumulator public strategy;
    
    /// @notice Current all-time high BTC price (18 decimals)
    uint256 public currentATH;
    
    /// @notice Last time ATH was updated
    uint256 public lastATHUpdate;
    
    /// @notice Total number of ATH updates (cycles)
    uint256 public athUpdateCount;

    /* ========== EVENTS ========== */

    event ATHUpdated(uint256 indexed cycleNumber, uint256 newATH, uint256 spotPrice);
    event PriceFeedUpdated(address indexed newFeed);
    event StrategyUpdated(address indexed newStrategy);

    /* ========== ERRORS ========== */

    error PriceDataStale();
    error InvalidPriceFeed();
    error PriceNotHigherThanATH();
    error InvalidStrategy();
    error ChainlinkAnswerInvalid();

    /* ========== INITIALIZER ========== */

    /**
     * @notice Initialize the oracle manager
     * @param _btcUsdFeed Chainlink BTC/USD price feed address
     * @param _strategy Strategy contract address  
     * @param _initialATH Initial ATH value (18 decimals)
     */
    function initialize(
        address _btcUsdFeed,
        address _strategy,
        uint256 _initialATH
    ) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);

        if (_btcUsdFeed == address(0)) revert InvalidPriceFeed();

        btcUsdFeed = AggregatorV3Interface(_btcUsdFeed);
        if (_strategy != address(0)) {
            strategy = IStrategyHybridAccumulator(_strategy);
        }
        currentATH = _initialATH;
        lastATHUpdate = block.timestamp;
        athUpdateCount = 0;
    }

    /* ========== KEEPER FUNCTIONS ========== */

    /**
     * @notice Update ATH if current spot price exceeds it
     * @dev Only callable by KEEPER_ROLE. Triggers strategy cycle reset on new ATH.
     */
    function updateATH() external onlyRole(KEEPER_ROLE) {
        uint256 spotPrice = getSpotPrice();
        
        if (spotPrice <= currentATH) {
            revert PriceNotHigherThanATH();
        }

        // Update ATH and trigger cycle reset
        currentATH = spotPrice;
        lastATHUpdate = block.timestamp;
        athUpdateCount++;

        // Notify strategy to reset cycle
        strategy.resetCycle();

        emit ATHUpdated(athUpdateCount, currentATH, spotPrice);
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get current BTC spot price from Chainlink
     * @dev Returns price in 18 decimals regardless of feed decimals
     * @return BTC price in 18 decimals
     */
    function getSpotPrice() public view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = btcUsdFeed.latestRoundData();
        
        // Check for stale price data
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) {
            revert PriceDataStale();
        }
        
        // Check for invalid price
        if (answer <= 0) {
            revert ChainlinkAnswerInvalid();
        }

        // Convert to 18 decimals
        uint256 feedDecimals = btcUsdFeed.decimals();
        
        if (feedDecimals <= 18) {
            return uint256(answer) * (10 ** (18 - feedDecimals));
        } else {
            return uint256(answer) / (10 ** (feedDecimals - 18));
        }
    }

    /**
     * @notice Check if redemptions are currently allowed
     * @dev Returns true if spot price is within the band: [95% of ATH, 100% of ATH]
     * @return True if redemption window is open
     */
    function isRedemptionWindowOpen() external view returns (bool) {
        uint256 spotPrice = getSpotPrice();
        uint256 redemptionFloor = (currentATH * (BPS_DENOMINATOR - REDEMPTION_BAND_BPS)) / BPS_DENOMINATOR;
        
        return spotPrice >= redemptionFloor && spotPrice <= currentATH;
    }

    /**
     * @notice Check if we're in price discovery mode (above ATH)
     * @dev Used internally by strategy, not for redemptions
     * @return True if spot price > current ATH
     */
    function isPriceDiscovery() external view returns (bool) {
        return getSpotPrice() > currentATH;
    }

    /**
     * @notice Get detailed price information
     * @return spotPrice Current BTC price (18 decimals)
     * @return athPrice Current ATH price (18 decimals)
     * @return redemptionFloor Minimum price for redemptions (18 decimals)
     * @return isWindowOpen Whether redemption window is open
     * @return isPriceDiscovering Whether price is above ATH
     */
    function getPriceInfo() 
        external 
        view 
        returns (
            uint256 spotPrice,
            uint256 athPrice,
            uint256 redemptionFloor,
            bool isWindowOpen,
            bool isPriceDiscovering
        )
    {
        spotPrice = getSpotPrice();
        athPrice = currentATH;
        redemptionFloor = (currentATH * (BPS_DENOMINATOR - REDEMPTION_BAND_BPS)) / BPS_DENOMINATOR;
        isWindowOpen = spotPrice >= redemptionFloor && spotPrice <= currentATH;
        isPriceDiscovering = spotPrice > currentATH;
    }

    /**
     * @notice Get ATH statistics
     * @return ath Current ATH value (18 decimals)
     * @return lastUpdate Timestamp of last ATH update
     * @return updateCount Total number of ATH updates
     */
    function getATHInfo() 
        external 
        view 
        returns (
            uint256 ath,
            uint256 lastUpdate,
            uint256 updateCount
        )
    {
        return (currentATH, lastATHUpdate, athUpdateCount);
    }

    /**
     * @notice Check if price data is fresh
     * @return True if price data is within staleness threshold
     */
    function isPriceDataFresh() external view returns (bool) {
        (, , , uint256 updatedAt, ) = btcUsdFeed.latestRoundData();
        return block.timestamp - updatedAt <= PRICE_STALENESS_THRESHOLD;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Update the BTC/USD price feed
     * @param _newFeed New Chainlink price feed address
     */
    function setBtcUsdFeed(address _newFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newFeed == address(0)) revert InvalidPriceFeed();
        btcUsdFeed = AggregatorV3Interface(_newFeed);
        emit PriceFeedUpdated(_newFeed);
    }

    /**
     * @notice Update the strategy contract
     * @param _newStrategy New strategy contract address
     */
    function setStrategy(address _newStrategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newStrategy == address(0)) revert InvalidStrategy();
        strategy = IStrategyHybridAccumulator(_newStrategy);
        emit StrategyUpdated(_newStrategy);
    }

    /**
     * @notice Manual ATH override (emergency function)
     * @dev Only for emergency use, bypasses normal price checks
     * @param _newATH New ATH value (18 decimals)
     */
    function setATHOverride(uint256 _newATH) external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentATH = _newATH;
        lastATHUpdate = block.timestamp;
        athUpdateCount++;
        
        emit ATHUpdated(athUpdateCount, currentATH, getSpotPrice());
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