// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategyOnChain } from "./interfaces/IStrategyOnChain.sol";
import { IAevoRouter } from "./interfaces/IAevo.sol";

/**
 * @title AevoAdapter — On-Chain Put Options via Aevo (Arbitrum)
 * @notice Manages OTM put positions as downside protection for the TPB strategy.
 *         Designed as a module called by StrategyOnChain.
 *
 * Features:
 *   - Flexible strikes + expiry (keeper-controlled, not hardcoded)
 *   - Premium limit per order (anti-sandwich/MEV protection)
 *   - Selective close by palier (matches strategy's tiered risk management)
 *   - totalPutValue() for NAV integration in StrategyOnChain.totalAssets()
 *   - Max 3 concurrent paliers, bounded allocation
 *
 * Palier mapping (optimized strategy):
 *   1 = Deep OTM put (~60% ATH) — catastrophe protection (0.5% TVL)
 *   2 = Mid OTM put  (~85% ATH) — moderate drawdown hedge (0.5% TVL)
 *   Total: 1% TVL in puts
 *
 * Reopening conditions (checked by StrategyOnChain.shouldReopenPuts):
 *   - BTC < -7% ATH OR HF < 2.6
 *
 * Roll down: close + reopen at lower strike when profit >= +70%
 */
contract AevoAdapter is AccessControl {
    using SafeERC20 for IERC20;

    // ======================== ROLES ========================
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ======================== IMMUTABLES ========================
    IAevoRouter public immutable aevoRouter;
    IStrategyOnChain public immutable strategy;
    IERC20 public immutable usdc;
    IERC20 public immutable wbtc;

    // ======================== CONSTANTS ========================
    uint8 public constant MAX_PALIERS = 3;
    uint256 public constant MAX_PREMIUM_SLIPPAGE_BPS = 500; // 5% max premium above limit
    uint256 public constant MAX_ALLOCATION_BPS = 500;        // max 5% of strategy TVL in puts

    // ======================== STATE ========================
    struct PutPosition {
        bytes32 orderId;
        uint256 strike;         // 8 decimals USD
        uint256 collateralUsdc; // 6 decimals
        uint256 expiry;
        uint256 premiumPaid;    // 6 decimals USDC
        bool active;
    }

    mapping(uint8 => PutPosition) public puts; // palier 1-3
    uint256 public totalAllocated;              // sum of active collateral

    // ======================== EVENTS ========================
    event PutOpened(uint8 indexed palier, uint256 strike, uint256 amount, uint256 expiry, uint256 premium);
    event PutClosed(uint8 indexed palier, int256 pnl, uint256 valueAtClose);
    event PutExpired(uint8 indexed palier, bytes32 orderId);
    event DefaultPremiumLimitUpdated(uint256 oldLimit, uint256 newLimit);

    // ======================== ERRORS ========================
    error InvalidPalier(uint8 palier);
    error PalierAlreadyActive(uint8 palier);
    error PalierNotActive(uint8 palier);
    error AllocationTooLarge(uint256 requested, uint256 max);
    error ExpiryTooSoon(uint256 expiry);
    error ExpiryTooFar(uint256 expiry);
    error StrikeTooHigh(uint256 strike, uint256 ath);
    error ZeroPremiumLimit();

    // ======================== CONFIG ========================
    uint256 public defaultPremiumLimitUsdc; // default max premium per order (6 dec)
    uint256 public constant MIN_EXPIRY_DURATION = 7 days;
    uint256 public constant MAX_EXPIRY_DURATION = 90 days;

    constructor(
        address aevoRouter_,
        address strategy_,
        address usdc_,
        address wbtc_,
        uint256 defaultPremiumLimit_
    ) {
        aevoRouter = IAevoRouter(aevoRouter_);
        strategy = IStrategyOnChain(strategy_);
        usdc = IERC20(usdc_);
        wbtc = IERC20(wbtc_);
        defaultPremiumLimitUsdc = defaultPremiumLimit_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    // ======================== OPEN PUTS ========================

    /// @notice Open a put on a specific palier with explicit params
    /// @param palier 1-3 (deep OTM → near ATM)
    /// @param strike Strike price in USD (8 decimals)
    /// @param amountUsdc USDC collateral (6 decimals)
    /// @param expiry Unix timestamp of option expiry
    /// @param premiumLimit Max premium in USDC (6 decimals). 0 = use default.
    function openPut(
        uint8 palier,
        uint256 strike,
        uint256 amountUsdc,
        uint256 expiry,
        uint256 premiumLimit
    ) external onlyRole(KEEPER_ROLE) {
        // Validate palier
        if (palier == 0 || palier > MAX_PALIERS) revert InvalidPalier(palier);
        if (puts[palier].active) revert PalierAlreadyActive(palier);

        // Validate expiry
        if (expiry < block.timestamp + MIN_EXPIRY_DURATION) revert ExpiryTooSoon(expiry);
        if (expiry > block.timestamp + MAX_EXPIRY_DURATION) revert ExpiryTooFar(expiry);

        // Validate strike: must be <= ATH (puts are OTM or ATM)
        uint256 ath = strategy.currentATH();
        if (ath > 0 && strike > ath) revert StrikeTooHigh(strike, ath);

        // Validate allocation: total puts <= 5% strategy TVL
        uint256 tvl = strategy.totalAssets();
        uint256 price = strategy.currentPrice();
        uint256 tvlUsdc = (tvl * price) / 1e8; // WBTC (8 dec) * price (8 dec) / 1e8 → 8 dec USD → /1e2 for 6 dec
        // Simplified: tvlUsdc in 6 decimals
        uint256 tvlUsdc6 = (tvl * price) / 1e10; // tvl(8dec) * price(8dec) / 1e10 → 6dec
        uint256 maxAlloc = (tvlUsdc6 * MAX_ALLOCATION_BPS) / 10_000;
        if (totalAllocated + amountUsdc > maxAlloc) {
            revert AllocationTooLarge(totalAllocated + amountUsdc, maxAlloc);
        }

        // Resolve premium limit
        uint256 effectivePremium = premiumLimit > 0 ? premiumLimit : defaultPremiumLimitUsdc;
        if (effectivePremium == 0) revert ZeroPremiumLimit();

        // Transfer USDC and open order
        usdc.safeTransferFrom(msg.sender, address(this), amountUsdc);
        usdc.forceApprove(address(aevoRouter), amountUsdc);

        bytes32 orderId = aevoRouter.openOrder(
            address(wbtc),
            false,              // put
            strike,
            amountUsdc,
            expiry,
            effectivePremium
        );

        // Track
        puts[palier] = PutPosition({
            orderId: orderId,
            strike: strike,
            collateralUsdc: amountUsdc,
            expiry: expiry,
            premiumPaid: effectivePremium, // approximate — actual may be less
            active: true
        });
        totalAllocated += amountUsdc;

        emit PutOpened(palier, strike, amountUsdc, expiry, effectivePremium);
    }

    /// @notice Convenience: open all 3 paliers at standard strikes
    /// @param totalUsdc Total USDC to allocate (split equally across 3 paliers)
    /// @param expiry Shared expiry for all 3 puts
    /// @param premiumLimitPerPut Max premium per put (6 dec USDC)
    /// @notice Open both puts: P1 (60% ATH) + P2 (85% ATH), split 50/50
    function openAllPuts(
        uint256 totalUsdc,
        uint256 expiry,
        uint256 premiumLimitPerPut
    ) external onlyRole(KEEPER_ROLE) {
        uint256 ath = strategy.currentATH();
        uint256 perPalier = totalUsdc / 2; // 2 paliers, not 3

        _openPutInternal(1, (ath * 60) / 100, perPalier, expiry, premiumLimitPerPut);
        _openPutInternal(2, (ath * 85) / 100, perPalier, expiry, premiumLimitPerPut);
    }

    function _openPutInternal(
        uint8 palier,
        uint256 strike,
        uint256 amountUsdc,
        uint256 expiry,
        uint256 premiumLimit
    ) internal {
        if (puts[palier].active) revert PalierAlreadyActive(palier);
        if (expiry < block.timestamp + MIN_EXPIRY_DURATION) revert ExpiryTooSoon(expiry);
        if (expiry > block.timestamp + MAX_EXPIRY_DURATION) revert ExpiryTooFar(expiry);

        uint256 effectivePremium = premiumLimit > 0 ? premiumLimit : defaultPremiumLimitUsdc;
        if (effectivePremium == 0) revert ZeroPremiumLimit();

        // Allocation check
        uint256 tvl = strategy.totalAssets();
        uint256 price = strategy.currentPrice();
        uint256 tvlUsdc6 = (tvl * price) / 1e10;
        uint256 maxAlloc = (tvlUsdc6 * MAX_ALLOCATION_BPS) / 10_000;
        if (totalAllocated + amountUsdc > maxAlloc) {
            revert AllocationTooLarge(totalAllocated + amountUsdc, maxAlloc);
        }

        usdc.forceApprove(address(aevoRouter), amountUsdc);

        bytes32 orderId = aevoRouter.openOrder(
            address(wbtc), false, strike, amountUsdc, expiry, effectivePremium
        );

        puts[palier] = PutPosition({
            orderId: orderId,
            strike: strike,
            collateralUsdc: amountUsdc,
            expiry: expiry,
            premiumPaid: effectivePremium,
            active: true
        });
        totalAllocated += amountUsdc;

        emit PutOpened(palier, strike, amountUsdc, expiry, effectivePremium);
    }

    // ======================== CLOSE PUTS (SELECTIVE) ========================

    /// @notice Close specific paliers. Matches tiered risk management rules:
    ///         -12.3% → close palier 1 (50% puts), -17.6% → close palier 2, etc.
    /// @param paliers Array of palier numbers to close
    function closePuts(uint8[] calldata paliers) external onlyRole(KEEPER_ROLE) {
        for (uint256 i = 0; i < paliers.length; i++) {
            _closePut(paliers[i]);
        }
    }

    /// @notice Close all active puts (used at ATH reset)
    function closeAllPuts() external onlyRole(KEEPER_ROLE) {
        for (uint8 i = 1; i <= MAX_PALIERS; i++) {
            if (puts[i].active) {
                _closePut(i);
            }
        }
    }

    function _closePut(uint8 palier) internal {
        if (palier == 0 || palier > MAX_PALIERS) revert InvalidPalier(palier);
        PutPosition storage pos = puts[palier];
        if (!pos.active) revert PalierNotActive(palier);

        // Read value BEFORE closing
        uint256 valueBeforeClose = aevoRouter.getPositionValue(pos.orderId);

        // Close and get realized PnL
        int256 pnl = aevoRouter.closeOrder(pos.orderId);

        // Update tracking
        totalAllocated -= pos.collateralUsdc;
        pos.active = false;

        emit PutClosed(palier, pnl, valueBeforeClose);
    }

    // ======================== ROLL DOWN ========================

    /// @notice Roll down a put: close at profit, reopen at lower strike (current price level)
    ///         Called when put is +70% profit — captures gain and re-establishes protection
    /// @param palier Which palier to roll down (1 or 2)
    /// @param newStrike New lower strike price (8 decimals)
    /// @param newExpiry New expiry timestamp
    /// @param premiumLimit Max premium for new put
    function rollDown(
        uint8 palier,
        uint256 newStrike,
        uint256 newExpiry,
        uint256 premiumLimit
    ) external onlyRole(KEEPER_ROLE) {
        if (palier == 0 || palier > MAX_PALIERS) revert InvalidPalier(palier);
        PutPosition storage pos = puts[palier];
        if (!pos.active) revert PalierNotActive(palier);

        // Read value and close
        uint256 valueBeforeClose = aevoRouter.getPositionValue(pos.orderId);
        int256 pnl = aevoRouter.closeOrder(pos.orderId);

        uint256 oldCollateral = pos.collateralUsdc;
        totalAllocated -= oldCollateral;
        pos.active = false;

        emit PutClosed(palier, pnl, valueBeforeClose);

        // Reopen at new strike with same allocation
        _openPutInternal(palier, newStrike, oldCollateral, newExpiry, premiumLimit);
    }

    // ======================== CLEANUP EXPIRED ========================

    /// @notice Mark expired puts as inactive (anyone can call)
    function cleanupExpired() external {
        for (uint8 i = 1; i <= MAX_PALIERS; i++) {
            PutPosition storage pos = puts[i];
            if (pos.active && block.timestamp > pos.expiry) {
                if (!aevoRouter.isPositionActive(pos.orderId)) {
                    totalAllocated -= pos.collateralUsdc;
                    pos.active = false;
                    emit PutExpired(i, pos.orderId);
                }
            }
        }
    }

    // ======================== VIEWS (NAV INTEGRATION) ========================

    /// @notice Total value of all active put positions in USDC (6 decimals)
    ///         Called by StrategyOnChain.totalAssets() for NAV calculation.
    function totalPutValue() external view returns (uint256) {
        uint256 total;
        for (uint8 i = 1; i <= MAX_PALIERS; i++) {
            if (puts[i].active) {
                total += aevoRouter.getPositionValue(puts[i].orderId);
            }
        }
        return total;
    }

    /// @notice Number of active put positions
    function activePutCount() external view returns (uint8 count) {
        for (uint8 i = 1; i <= MAX_PALIERS; i++) {
            if (puts[i].active) count++;
        }
    }

    /// @notice Get details of a specific palier
    function getPut(uint8 palier) external view returns (
        bytes32 orderId,
        uint256 strike,
        uint256 collateralUsdc,
        uint256 expiry,
        uint256 currentValue,
        bool active
    ) {
        PutPosition memory pos = puts[palier];
        uint256 value = pos.active ? aevoRouter.getPositionValue(pos.orderId) : 0;
        return (pos.orderId, pos.strike, pos.collateralUsdc, pos.expiry, value, pos.active);
    }

    // ======================== ADMIN ========================

    function setDefaultPremiumLimit(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit DefaultPremiumLimitUpdated(defaultPremiumLimitUsdc, newLimit);
        defaultPremiumLimitUsdc = newLimit;
    }

    /// @notice Rescue stuck USDC (e.g. after failed close)
    function rescueUsdc(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdc.safeTransfer(to, amount);
    }

    // ======================== RECEIVE ========================
    receive() external payable {} // for potential ETH refunds
}
