// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategyOnChain } from "./interfaces/IStrategyOnChain.sol";
import { IAavePool, IAaveOracle, IAToken, IVariableDebtToken } from "./interfaces/IAaveV3.sol";
import { IGMXExchangeRouter, IGMXReader, IOrderCallbackReceiver } from "./interfaces/IGMXV2.sol";
import { AevoAdapter } from "./AevoAdapter.sol";
import { ICamelotRouter } from "./interfaces/ICamelot.sol";

/**
 * @title StrategyOnChain — Full On-Chain Arbitrum (Optimized)
 * @notice Manages the TPB vault strategy: AAVE V3 + GMX V2 shorts + Aevo puts.
 *
 * STRATEGY RULES (validated version):
 *
 *   Allocation: 82% WBTC / 15% USDC buffer / 3% hedging (2% GMX + 1% Aevo)
 *
 *   SHORTS GMX (2% TVL total):
 *     - 1% "profit-taking": partial close at +12% / +25% / +40% profit
 *     - 1% "insurance": close only on -8% recovery from bottom OR new ATH
 *     - Trailing stop 60% max profit on both halves
 *     - Max 3 reopenings per cycle at -8% / -15% from last open price
 *
 *   PUTS AEVO (1% TVL total):
 *     - P1: 0.5% TVL, strike 60% ATH
 *     - P2: 0.5% TVL, strike 85% ATH
 *     - Reopen if BTC < -7% ATH OR HF < 2.6
 *     - Roll down on +70% profit
 *
 *   CASH FLOW PRIORITY:
 *     1. HF < 1.85 → 100% repay debt
 *     2. HF 1.85-2.0 → 50% debt / 50% buy WBTC
 *     3. HF ≥ 2.0 → priority buy WBTC
 *     4. Keep 2% TVL USDC reserve
 *
 *   EXIT FEES: Progressive (in vault)
 *   REBALANCING: ±3% or every 14 days
 *   FULL UNWIND: automatic at new ATH
 */
contract StrategyOnChain is IStrategyOnChain, AccessControl, IOrderCallbackReceiver {
    using SafeERC20 for IERC20;

    // ======================== ROLES ========================
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ======================== STATE MACHINE ========================
    enum Phase { IDLE, HEDGED, CLOSING }
    Phase public phase;

    uint256 public override currentATH;
    uint256 public pendingCloseOrders;

    // ======================== IMMUTABLES ========================
    address public immutable vault;
    IAavePool public immutable aavePool;
    IAaveOracle public immutable aaveOracle;
    IGMXExchangeRouter public immutable gmxRouter;
    IGMXReader public immutable gmxReader;
    address public immutable gmxDataStore;
    bytes32 public immutable gmxMarketKey;
    address public immutable gmxOrderVault;

    IERC20 public immutable wbtc;
    IERC20 public immutable usdc;
    IAToken public immutable aWbtc;
    IVariableDebtToken public immutable debtUsdc;

    // ======================== AEVO (PUTS) ========================
    AevoAdapter public aevoAdapter;

    // ======================== DEX (CAMELOT) ========================
    ICamelotRouter public dexRouter;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 public constant SWAP_SLIPPAGE_BPS = 50; // 0.5% default

    // ======================== STRATEGY CONSTANTS ========================
    // Allocation
    uint256 public constant TARGET_WBTC_BPS     = 8200;  // 82%
    uint256 public constant TARGET_BUFFER_BPS   = 1500;  // 15%
    uint256 public constant TARGET_HEDGE_BPS    = 300;    // 3%
    uint256 public constant SHORT_ALLOC_BPS     = 200;    // 2% TVL for shorts
    uint256 public constant PUT_ALLOC_BPS       = 100;    // 1% TVL for puts
    uint256 public constant USDC_RESERVE_BPS    = 200;    // 2% TVL reserve

    // Short profit-taking thresholds
    uint256 public constant PT_CLOSE_1_BPS      = 1200;   // +12% → close 30%
    uint256 public constant PT_CLOSE_1_PCT      = 3000;   // 30% of position
    uint256 public constant PT_CLOSE_2_BPS      = 2500;   // +25% → close 50% of remainder
    uint256 public constant PT_CLOSE_2_PCT      = 5000;   // 50%
    uint256 public constant PT_CLOSE_3_BPS      = 4000;   // +40% → close 100%
    uint256 public constant PT_CLOSE_3_PCT      = 10000;  // 100%

    // Insurance close
    uint256 public constant INS_RECOVERY_BPS    = 800;    // close insurance at -8% recovery from bottom
    uint256 public constant TRAILING_STOP_BPS   = 6000;   // 60% of max profit

    // Reopening
    uint256 public constant REOPEN_1_BPS        = 800;    // -8% from last open → reopen 50%
    uint256 public constant REOPEN_2_BPS        = 1500;   // -15% from last open → reopen 100%
    uint256 public constant MAX_REOPENINGS      = 3;

    // Put reopening conditions
    uint256 public constant PUT_REOPEN_DROP_BPS = 700;    // BTC < -7% ATH
    uint256 public constant PUT_REOPEN_HF       = 2.6e18; // HF < 2.6
    uint256 public constant PUT_ROLLDOWN_BPS    = 7000;   // +70% profit → roll down

    // Cash flow HF thresholds
    uint256 public constant HF_CRITICAL         = 1.85e18;
    uint256 public constant HF_MODERATE         = 2.0e18;

    // Rebalancing
    uint256 public constant REBAL_DRIFT_BPS     = 300;    // ±3%
    uint256 public constant REBAL_INTERVAL      = 14 days;

    // Safety
    uint256 public constant MAX_ATH_DELTA_BPS   = 1000;
    uint256 public constant MAX_LTV_BPS         = 5000;
    uint256 public constant SLIPPAGE_BPS        = 100;

    uint256 private constant USD_DECIMALS  = 1e8;
    uint256 private constant GMX_DECIMALS  = 1e30;
    uint256 private constant WBTC_DECIMALS = 1e8;
    uint256 private constant USDC_DECIMALS = 1e6;

    // ======================== SHORT POSITION TRACKING ========================
    enum ShortType { PROFIT_TAKING, INSURANCE }

    struct ShortPosition {
        bytes32 gmxPositionKey;
        uint256 sizeUsd;          // GMX 30-decimal
        uint256 collateralUsdc;
        uint256 openPrice;        // BTC price at open (8 dec)
        uint256 maxProfitBps;     // max observed profit in BPS
        ShortType shortType;
        bool active;
    }
    ShortPosition[] public shorts;
    mapping(bytes32 => uint256) public orderToShortIndex;

    // ======================== CYCLE TRACKING ========================
    uint256 public cycleReopenings;       // count of reopenings this cycle
    uint256 public lastOpenPrice;         // BTC price at last short opening
    uint256 public lowestPriceSinceOpen;  // for insurance recovery tracking
    uint256 public lastRebalanceTime;

    // ======================== EVENTS ========================
    event ATHUpdated(uint256 oldATH, uint256 newATH);
    event PhaseChanged(Phase from, Phase to);
    event ShortOpened(uint256 indexed index, ShortType shortType, uint256 sizeUsd, uint256 collateralUsdc);
    event ShortClosed(uint256 indexed index, ShortType shortType);
    event ShortCloseInitiated(uint256 indexed index, bytes32 orderKey);
    event ShortPartialClose(uint256 indexed index, uint256 closePct, uint256 profitBps);
    event GMXOrderCallback(bytes32 indexed orderKey, bool executed);
    event DepositedToStrategy(uint256 amount);
    event WithdrawnFromStrategy(uint256 amount, address to);
    event DebtRepaid(uint256 amount);
    event WBTCAccumulated(uint256 amount);
    event CashFlowExecuted(uint256 debtRepaid, uint256 wbtcBought, uint256 reserveKept);
    event Rebalanced(uint256 wbtcPct, uint256 bufferPct, uint256 hedgePct);
    event AevoAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event BoughtWBTC(uint256 usdcIn, uint256 wbtcOut);
    event SoldWBTC(uint256 wbtcIn, uint256 usdcOut);
    event PriceTracked(uint256 price, uint256 lowestSinceOpen);

    // ======================== ERRORS ========================
    error OnlyVault();
    error OnlyGMXRouter();
    error PriceDiscoveryActive();
    error ShortTooLarge(uint256 requested, uint256 max);
    error ATHDeltaTooLarge(uint256 delta);
    error LTVTooHigh(uint256 current, uint256 max);
    error InsufficientLiquidity();
    error ShortNotActive();
    error MaxReopeningsReached();
    error RebalanceTooSoon();

    // ======================== MODIFIERS ========================
    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyGMX() {
        if (msg.sender != address(gmxRouter)) revert OnlyGMXRouter();
        _;
    }

    constructor(
        address vault_,
        address aavePool_,
        address aaveOracle_,
        address gmxRouter_,
        address gmxReader_,
        address gmxDataStore_,
        bytes32 gmxMarketKey_,
        address gmxOrderVault_,
        address wbtc_,
        address usdc_,
        address aWbtc_,
        address debtUsdc_
    ) {
        vault = vault_;
        aavePool = IAavePool(aavePool_);
        aaveOracle = IAaveOracle(aaveOracle_);
        gmxRouter = IGMXExchangeRouter(gmxRouter_);
        gmxReader = IGMXReader(gmxReader_);
        gmxDataStore = gmxDataStore_;
        gmxMarketKey = gmxMarketKey_;
        gmxOrderVault = gmxOrderVault_;
        wbtc = IERC20(wbtc_);
        usdc = IERC20(usdc_);
        aWbtc = IAToken(aWbtc_);
        debtUsdc = IVariableDebtToken(debtUsdc_);
        lastRebalanceTime = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    // ======================== VAULT INTERFACE ========================

    function deposit(uint256 amount) external override onlyVault {
        wbtc.safeTransferFrom(vault, address(this), amount);
        wbtc.safeIncreaseAllowance(address(aavePool), amount);
        aavePool.supply(address(wbtc), amount, address(this), 0);
        emit DepositedToStrategy(amount);
    }

    function withdraw(uint256 amount, address to) external override onlyVault returns (uint256) {
        uint256 available = _availableWbtc();
        if (amount > available) revert InsufficientLiquidity();
        uint256 received = aavePool.withdraw(address(wbtc), amount, to);
        emit WithdrawnFromStrategy(received, to);
        return received;
    }

    // ======================== ATH MANAGEMENT ========================

    function updateATH(uint256 newPrice) external onlyRole(KEEPER_ROLE) {
        if (newPrice <= currentATH) return;

        if (currentATH > 0) {
            uint256 delta = ((newPrice - currentATH) * 10_000) / currentATH;
            if (delta > MAX_ATH_DELTA_BPS) revert ATHDeltaTooLarge(delta);
        }

        uint256 oldATH = currentATH;
        currentATH = newPrice;
        emit ATHUpdated(oldATH, newPrice);

        // Full unwind at new ATH
        if (phase == Phase.HEDGED) {
            _enterClosingPhase();
        }

        // Reset cycle counters
        cycleReopenings = 0;
    }

    // ======================== OPEN SHORTS (SPLIT: PROFIT-TAKING + INSURANCE) ========================

    /// @notice Open both halves: 1% profit-taking + 1% insurance
    /// @param totalSizeUsd Total short size in GMX 30-decimal USD
    /// @param totalCollateralUsdc Total USDC collateral (6 dec)
    function openHedgeShorts(
        uint256 totalSizeUsd,
        uint256 totalCollateralUsdc
    ) external payable onlyRole(KEEPER_ROLE) {
        if (phase == Phase.CLOSING) revert PriceDiscoveryActive();

        uint256 halfSize = totalSizeUsd / 2;
        uint256 halfCollateral = totalCollateralUsdc / 2;

        // Borrow total USDC from AAVE
        aavePool.borrow(address(usdc), totalCollateralUsdc, 2, 0, address(this));
        _checkLTV();

        uint256 price = _wbtcPriceUsd();
        lastOpenPrice = price;
        lowestPriceSinceOpen = price;

        // Open profit-taking half
        _openShortGMX(halfSize, halfCollateral, price, ShortType.PROFIT_TAKING, msg.value / 2);

        // Open insurance half
        _openShortGMX(halfSize, halfCollateral, price, ShortType.INSURANCE, msg.value - msg.value / 2);

        if (phase == Phase.IDLE) {
            phase = Phase.HEDGED;
            emit PhaseChanged(Phase.IDLE, Phase.HEDGED);
        }
    }

    function _openShortGMX(
        uint256 sizeUsd,
        uint256 collateralUsdc,
        uint256 price,
        ShortType sType,
        uint256 execFee
    ) internal {
        // Bound check
        uint256 tvlWbtc = this.totalAssets();
        uint256 tvlUsd30 = tvlWbtc * price * (GMX_DECIMALS / USD_DECIMALS) / WBTC_DECIMALS;
        uint256 maxSize = (tvlUsd30 * SHORT_ALLOC_BPS) / 10_000;
        if (sizeUsd > maxSize) revert ShortTooLarge(sizeUsd, maxSize);

        usdc.safeIncreaseAllowance(address(gmxRouter), collateralUsdc);
        gmxRouter.sendTokens(address(usdc), gmxOrderVault, collateralUsdc);
        gmxRouter.sendWnt{value: execFee}(gmxOrderVault, execFee);

        uint256 acceptablePrice30 = price * (GMX_DECIMALS / USD_DECIMALS)
            * (10_000 - SLIPPAGE_BPS) / 10_000;

        address[] memory emptyPath = new address[](0);

        IGMXExchangeRouter.CreateOrderParams memory params = IGMXExchangeRouter.CreateOrderParams({
            addresses: IGMXExchangeRouter.CreateOrderParamsAddresses({
                receiver: address(this),
                callbackContract: address(this),
                uiFeeReceiver: address(0),
                market: address(uint160(uint256(gmxMarketKey))),
                initialCollateralToken: address(usdc),
                swapPath: emptyPath
            }),
            numbers: IGMXExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeUsd,
                initialCollateralDeltaAmount: collateralUsdc,
                triggerPrice: 0,
                acceptablePrice: acceptablePrice30,
                executionFee: execFee,
                callbackGasLimit: 300_000,
                minOutputAmount: 0
            }),
            orderType: bytes32(uint256(1)),
            decreasePositionSwapType: bytes32(0),
            isLong: false,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        bytes32 orderKey = gmxRouter.createOrder(params);

        uint256 idx = shorts.length;
        shorts.push(ShortPosition({
            gmxPositionKey: orderKey,
            sizeUsd: sizeUsd,
            collateralUsdc: collateralUsdc,
            openPrice: price,
            maxProfitBps: 0,
            shortType: sType,
            active: false
        }));
        orderToShortIndex[orderKey] = idx;

        emit ShortOpened(idx, sType, sizeUsd, collateralUsdc);
    }

    // ======================== KEEPER: CHECK & MANAGE POSITIONS ========================

    /// @notice Keeper calls this periodically to manage positions based on strategy rules.
    ///         Tracks price, checks profit-taking thresholds, insurance recovery, trailing stops.
    function managePositions() external onlyRole(KEEPER_ROLE) {
        uint256 price = _wbtcPriceUsd();

        // Track lowest price for insurance recovery
        if (price < lowestPriceSinceOpen) {
            lowestPriceSinceOpen = price;
        }
        emit PriceTracked(price, lowestPriceSinceOpen);

        for (uint256 i = 0; i < shorts.length; i++) {
            ShortPosition storage pos = shorts[i];
            if (!pos.active) continue;

            // Calculate current profit in BPS
            uint256 profitBps = 0;
            if (price < pos.openPrice) {
                profitBps = ((pos.openPrice - price) * 10_000) / pos.openPrice;
            }

            // Update max profit
            if (profitBps > pos.maxProfitBps) {
                pos.maxProfitBps = profitBps;
            }

            // === TRAILING STOP (both halves) ===
            // If profit dropped below 60% of max observed profit, close
            if (pos.maxProfitBps > 500 && profitBps > 0) { // only if max was meaningful (>5%)
                uint256 trailingThreshold = (pos.maxProfitBps * TRAILING_STOP_BPS) / 10_000;
                if (profitBps < trailingThreshold) {
                    // Trailing stop triggered — mark for close
                    // Keeper must call closeShort(i) separately due to async GMX
                    emit ShortPartialClose(i, 10_000, profitBps);
                }
            }

            if (pos.shortType == ShortType.PROFIT_TAKING) {
                // === PROFIT-TAKING RULES ===
                if (profitBps >= PT_CLOSE_3_BPS) {
                    emit ShortPartialClose(i, PT_CLOSE_3_PCT, profitBps);
                } else if (profitBps >= PT_CLOSE_2_BPS) {
                    emit ShortPartialClose(i, PT_CLOSE_2_PCT, profitBps);
                } else if (profitBps >= PT_CLOSE_1_BPS) {
                    emit ShortPartialClose(i, PT_CLOSE_1_PCT, profitBps);
                }
            } else {
                // === INSURANCE RULES ===
                // Close on recovery: price recovered -8% from the lowest point
                if (lowestPriceSinceOpen > 0 && price > lowestPriceSinceOpen) {
                    uint256 recoveryBps = ((price - lowestPriceSinceOpen) * 10_000) / lowestPriceSinceOpen;
                    if (recoveryBps >= INS_RECOVERY_BPS) {
                        emit ShortPartialClose(i, 10_000, profitBps);
                    }
                }
            }
        }
    }

    /// @notice Check if shorts should be reopened based on price drops from last open
    function checkReopening() external view returns (bool shouldReopen, uint256 reopenPct) {
        if (cycleReopenings >= MAX_REOPENINGS) return (false, 0);
        uint256 price = _wbtcPriceUsd();
        if (lastOpenPrice == 0) return (false, 0);

        uint256 dropBps = 0;
        if (price < lastOpenPrice) {
            dropBps = ((lastOpenPrice - price) * 10_000) / lastOpenPrice;
        }

        if (dropBps >= REOPEN_2_BPS) return (true, 10_000);  // 100%
        if (dropBps >= REOPEN_1_BPS) return (true, 5_000);   // 50%
        return (false, 0);
    }

    /// @notice Keeper calls to reopen shorts after price drop
    function reopenShorts(
        uint256 sizeUsd,
        uint256 collateralUsdc
    ) external payable onlyRole(KEEPER_ROLE) {
        if (cycleReopenings >= MAX_REOPENINGS) revert MaxReopeningsReached();
        cycleReopenings++;

        uint256 price = _wbtcPriceUsd();
        lastOpenPrice = price;

        aavePool.borrow(address(usdc), collateralUsdc, 2, 0, address(this));
        _checkLTV();

        uint256 halfSize = sizeUsd / 2;
        uint256 halfCollateral = collateralUsdc / 2;

        _openShortGMX(halfSize, halfCollateral, price, ShortType.PROFIT_TAKING, msg.value / 2);
        _openShortGMX(halfSize, halfCollateral, price, ShortType.INSURANCE, msg.value - msg.value / 2);
    }

    // ======================== CLOSE SHORT ========================

    function _enterClosingPhase() internal {
        uint256 count;
        for (uint256 i = 0; i < shorts.length; i++) {
            if (shorts[i].active) count++;
        }
        pendingCloseOrders = count;
        phase = Phase.CLOSING;
        emit PhaseChanged(Phase.HEDGED, Phase.CLOSING);

        // Close all Aevo puts on ATH
        if (address(aevoAdapter) != address(0)) {
            try aevoAdapter.closeAllPuts() {} catch {}
        }
    }

    function closeShort(uint256 index) external payable onlyRole(KEEPER_ROLE) {
        ShortPosition storage pos = shorts[index];
        if (!pos.active) revert ShortNotActive();

        gmxRouter.sendWnt{value: msg.value}(gmxOrderVault, msg.value);

        uint256 price = _wbtcPriceUsd();
        uint256 acceptablePrice30 = price * (GMX_DECIMALS / USD_DECIMALS)
            * (10_000 + SLIPPAGE_BPS) / 10_000;

        address[] memory emptyPath = new address[](0);

        IGMXExchangeRouter.CreateOrderParams memory params = IGMXExchangeRouter.CreateOrderParams({
            addresses: IGMXExchangeRouter.CreateOrderParamsAddresses({
                receiver: address(this),
                callbackContract: address(this),
                uiFeeReceiver: address(0),
                market: address(uint160(uint256(gmxMarketKey))),
                initialCollateralToken: address(usdc),
                swapPath: emptyPath
            }),
            numbers: IGMXExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: pos.sizeUsd,
                initialCollateralDeltaAmount: 0,
                triggerPrice: 0,
                acceptablePrice: acceptablePrice30,
                executionFee: msg.value,
                callbackGasLimit: 300_000,
                minOutputAmount: 0
            }),
            orderType: bytes32(uint256(4)),
            decreasePositionSwapType: bytes32(0),
            isLong: false,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        bytes32 orderKey = gmxRouter.createOrder(params);
        orderToShortIndex[orderKey] = index;

        emit ShortCloseInitiated(index, orderKey);
    }

    // ======================== CASH FLOW MANAGEMENT ========================

    /// @notice Execute cash flow priority rules based on HF
    function executeCashFlow() external onlyRole(KEEPER_ROLE) {
        uint256 usdcBal = usdc.balanceOf(address(this));
        if (usdcBal == 0) return;

        uint256 hf = _getHealthFactor();
        uint256 tvlUsdc6 = _tvlInUsdc6();
        uint256 reserveTarget = (tvlUsdc6 * USDC_RESERVE_BPS) / 10_000;

        // Keep reserve
        uint256 available = usdcBal > reserveTarget ? usdcBal - reserveTarget : 0;
        if (available == 0) return;

        uint256 debtPaid = 0;
        uint256 wbtcBought = 0;

        if (hf < HF_CRITICAL) {
            // 100% to repay debt
            debtPaid = _repayDebt(available);
        } else if (hf < HF_MODERATE) {
            // 50/50 debt + WBTC
            uint256 halfDebt = available / 2;
            debtPaid = _repayDebt(halfDebt);
            wbtcBought = _buyWBTC(available - halfDebt);
        } else {
            // Priority WBTC
            wbtcBought = _buyWBTC(available);
        }

        emit CashFlowExecuted(debtPaid, wbtcBought, reserveTarget);
    }

    function _repayDebt(uint256 amount) internal returns (uint256) {
        uint256 debt = debtUsdc.balanceOf(address(this));
        if (debt == 0 || amount == 0) return 0;
        uint256 repayAmount = amount < debt ? amount : debt;
        usdc.safeIncreaseAllowance(address(aavePool), repayAmount);
        aavePool.repay(address(usdc), repayAmount, 2, address(this));
        emit DebtRepaid(repayAmount);
        return repayAmount;
    }

    function _buyWBTC(uint256 usdcAmount) internal returns (uint256) {
        if (usdcAmount == 0 || address(dexRouter) == address(0)) return 0;

        uint256 wbtcReceived = _swapUSDCtoWBTC(usdcAmount, SWAP_SLIPPAGE_BPS);

        // Supply bought WBTC to AAVE as collateral
        if (wbtcReceived > 0) {
            wbtc.safeIncreaseAllowance(address(aavePool), wbtcReceived);
            aavePool.supply(address(wbtc), wbtcReceived, address(this), 0);
        }

        emit WBTCAccumulated(wbtcReceived);
        return wbtcReceived;
    }

    // ======================== DEX SWAP HELPERS ========================

    /// @notice Swap USDC → WETH → WBTC via Camelot
    function _swapUSDCtoWBTC(uint256 usdcAmount, uint256 slippageBps) internal returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = address(usdc);
        path[1] = WETH;
        path[2] = address(wbtc);

        uint256[] memory amountsOut = dexRouter.getAmountsOut(usdcAmount, path);
        uint256 minOut = (amountsOut[2] * (10_000 - slippageBps)) / 10_000;

        usdc.forceApprove(address(dexRouter), usdcAmount);
        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
            usdcAmount, minOut, path, address(this), block.timestamp + 300
        );

        emit BoughtWBTC(usdcAmount, amounts[2]);
        return amounts[2];
    }

    /// @notice Swap WBTC → WETH → USDC via Camelot (for rebalancing)
    function _swapWBTCtoUSDC(uint256 wbtcAmount, uint256 slippageBps) internal returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = address(wbtc);
        path[1] = WETH;
        path[2] = address(usdc);

        uint256[] memory amountsOut = dexRouter.getAmountsOut(wbtcAmount, path);
        uint256 minOut = (amountsOut[2] * (10_000 - slippageBps)) / 10_000;

        wbtc.forceApprove(address(dexRouter), wbtcAmount);
        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
            wbtcAmount, minOut, path, address(this), block.timestamp + 300
        );

        emit SoldWBTC(wbtcAmount, amounts[2]);
        return amounts[2];
    }

    /// @notice Keeper can manually trigger a WBTC purchase (with custom slippage)
    function buyWBTC(uint256 usdcAmount, uint256 slippageBps) external onlyRole(KEEPER_ROLE) {
        uint256 received = _swapUSDCtoWBTC(usdcAmount, slippageBps > 0 ? slippageBps : SWAP_SLIPPAGE_BPS);
        // Supply to AAVE
        if (received > 0) {
            wbtc.safeIncreaseAllowance(address(aavePool), received);
            aavePool.supply(address(wbtc), received, address(this), 0);
        }
    }

    // ======================== REBALANCING ========================

    uint256 public constant MIN_REBAL_AMOUNT_USD = 100e8; // $100 minimum to avoid micro-swaps

    /// @notice View for keeper: should we rebalance?
    function shouldRebalance() public view returns (bool) {
        if (block.timestamp >= lastRebalanceTime + REBAL_INTERVAL) return true;
        (int256 wbtcDrift, ) = _calculateDriftBps();
        return wbtcDrift > int256(REBAL_DRIFT_BPS) || wbtcDrift < -int256(REBAL_DRIFT_BPS);
    }

    /// @notice Calculate WBTC allocation drift from target (82%)
    /// @return wbtcDrift Positive = WBTC overweight, negative = WBTC underweight
    /// @return absDrift Absolute drift value
    function _calculateDriftBps() internal view returns (int256 wbtcDrift, uint256 absDrift) {
        (uint256 wbtcPct, , ) = _getAllocationPcts();
        wbtcDrift = int256(wbtcPct) - int256(TARGET_WBTC_BPS);
        absDrift = wbtcDrift >= 0 ? uint256(wbtcDrift) : uint256(-wbtcDrift);
    }

    /// @notice Rebalance portfolio toward 82/15/3 target allocation
    /// @param slippageBps Custom slippage (0 = use default 0.5%)
    function rebalance(uint256 slippageBps) external onlyRole(KEEPER_ROLE) {
        if (!shouldRebalance()) revert RebalanceTooSoon();

        slippageBps = slippageBps == 0 ? SWAP_SLIPPAGE_BPS : slippageBps;

        (int256 wbtcDrift, uint256 absDrift) = _calculateDriftBps();
        uint256 price = _wbtcPriceUsd();

        if (wbtcDrift > int256(REBAL_DRIFT_BPS)) {
            // WBTC overweight → withdraw some WBTC from AAVE, swap to USDC
            // Calculate WBTC amount to sell (in 8 decimals)
            uint256 tvlUsd8 = (this.totalAssets() * price) / WBTC_DECIMALS;
            uint256 sellValueUsd8 = (tvlUsd8 * absDrift) / 10_000;

            if (sellValueUsd8 > MIN_REBAL_AMOUNT_USD) {
                uint256 wbtcToSell = (sellValueUsd8 * WBTC_DECIMALS) / price;
                uint256 available = _availableWbtc();
                if (wbtcToSell > available) wbtcToSell = available;

                if (wbtcToSell > 0) {
                    // Withdraw from AAVE
                    aavePool.withdraw(address(wbtc), wbtcToSell, address(this));
                    // Swap to USDC
                    _swapWBTCtoUSDC(wbtcToSell, slippageBps);
                }
            }
        } else if (wbtcDrift < -int256(REBAL_DRIFT_BPS)) {
            // WBTC underweight → swap USDC to WBTC, supply to AAVE
            uint256 tvlUsd8 = (this.totalAssets() * price) / WBTC_DECIMALS;
            uint256 buyValueUsd8 = (tvlUsd8 * absDrift) / 10_000;

            if (buyValueUsd8 > MIN_REBAL_AMOUNT_USD) {
                // Convert USD (8 dec) → USDC (6 dec)
                uint256 usdcToBuy = (buyValueUsd8 * USDC_DECIMALS) / USD_DECIMALS;
                uint256 usdcBal = usdc.balanceOf(address(this));
                // Keep 2% reserve
                uint256 tvlUsdc6 = _tvlInUsdc6();
                uint256 reserve = (tvlUsdc6 * USDC_RESERVE_BPS) / 10_000;
                uint256 spendable = usdcBal > reserve ? usdcBal - reserve : 0;
                if (usdcToBuy > spendable) usdcToBuy = spendable;

                if (usdcToBuy > 0) {
                    uint256 wbtcReceived = _swapUSDCtoWBTC(usdcToBuy, slippageBps);
                    // Supply to AAVE
                    if (wbtcReceived > 0) {
                        wbtc.safeIncreaseAllowance(address(aavePool), wbtcReceived);
                        aavePool.supply(address(wbtc), wbtcReceived, address(this), 0);
                    }
                }
            }
        }

        lastRebalanceTime = block.timestamp;

        (uint256 wbtcPct, uint256 bufferPct, uint256 hedgePct) = _getAllocationPcts();
        emit Rebalanced(wbtcPct, bufferPct, hedgePct);
    }

    // Use rebalance(0) for default slippage

    function _getAllocationPcts() internal view returns (uint256 wbtcPct, uint256 bufferPct, uint256 hedgePct) {
        uint256 price = _wbtcPriceUsd();
        if (price == 0) return (0, 0, 0);

        uint256 wbtcVal = (aWbtc.balanceOf(address(this)) * price) / WBTC_DECIMALS;
        uint256 usdcVal = (usdc.balanceOf(address(this)) * USD_DECIMALS) / USDC_DECIMALS;
        // Hedge value = GMX collateral + Aevo puts
        uint256 hedgeVal = _totalHedgeValueUsd8();

        uint256 total = wbtcVal + usdcVal + hedgeVal;
        if (total == 0) return (0, 0, 0);

        wbtcPct = (wbtcVal * 10_000) / total;
        bufferPct = (usdcVal * 10_000) / total;
        hedgePct = (hedgeVal * 10_000) / total;
    }

    function _totalHedgeValueUsd8() internal view returns (uint256) {
        uint256 gmxVal = 0;
        for (uint256 i = 0; i < shorts.length; i++) {
            if (shorts[i].active) {
                gmxVal += (shorts[i].collateralUsdc * USD_DECIMALS) / USDC_DECIMALS;
            }
        }
        uint256 aevoVal = 0;
        if (address(aevoAdapter) != address(0)) {
            aevoVal = (aevoAdapter.totalPutValue() * USD_DECIMALS) / USDC_DECIMALS;
        }
        return gmxVal + aevoVal;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // ======================== PUT MANAGEMENT HELPERS ========================

    /// @notice Check if puts should be reopened
    function shouldReopenPuts() external view returns (bool) {
        if (address(aevoAdapter) == address(0)) return false;
        if (aevoAdapter.activePutCount() >= 2) return false; // already have puts

        uint256 price = _wbtcPriceUsd();

        // Condition 1: BTC < -7% ATH
        if (currentATH > 0 && price < (currentATH * (10_000 - PUT_REOPEN_DROP_BPS)) / 10_000) {
            return true;
        }

        // Condition 2: HF < 2.6
        uint256 hf = _getHealthFactor();
        if (hf < PUT_REOPEN_HF) {
            return true;
        }

        return false;
    }

    /// @notice Check if a put should be rolled down (+70% profit)
    function shouldRollDown(uint8 palier) external view returns (bool) {
        if (address(aevoAdapter) == address(0)) return false;
        (, , uint256 collateral, , uint256 currentValue, bool active) = aevoAdapter.getPut(palier);
        if (!active || collateral == 0) return false;
        uint256 profitBps = ((currentValue - collateral) * 10_000) / collateral;
        return currentValue > collateral && profitBps >= PUT_ROLLDOWN_BPS;
    }

    // ======================== GMX CALLBACKS ========================

    function afterOrderExecution(
        bytes32 key, bytes calldata, bytes calldata
    ) external override onlyGMX {
        uint256 idx = orderToShortIndex[key];
        ShortPosition storage pos = shorts[idx];

        if (!pos.active) {
            pos.active = true;
        } else {
            pos.active = false;
            emit ShortClosed(idx, pos.shortType);

            // C4: Compact shorts array — swap with last and pop
            uint256 lastIdx = shorts.length - 1;
            if (idx != lastIdx) {
                shorts[idx] = shorts[lastIdx];
                // Update orderToShortIndex for the moved entry
                orderToShortIndex[shorts[idx].gmxPositionKey] = idx;
            }
            shorts.pop();
            delete orderToShortIndex[key];

            if (pendingCloseOrders > 0) {
                pendingCloseOrders--;
                if (pendingCloseOrders == 0 && phase == Phase.CLOSING) {
                    _repayAllDebt();
                    phase = Phase.IDLE;
                    emit PhaseChanged(Phase.CLOSING, Phase.IDLE);
                }
            }
        }
        emit GMXOrderCallback(key, true);
    }

    function afterOrderCancellation(
        bytes32 key, bytes calldata, bytes calldata
    ) external override onlyGMX {
        uint256 idx = orderToShortIndex[key];
        ShortPosition storage pos = shorts[idx];
        if (!pos.active) {
            pos.sizeUsd = 0;
            pos.collateralUsdc = 0;
        } else {
            if (pendingCloseOrders > 0) pendingCloseOrders--;
        }
        emit GMXOrderCallback(key, false);
    }

    function afterOrderFrozen(
        bytes32 key, bytes calldata, bytes calldata
    ) external override onlyGMX {
        emit GMXOrderCallback(key, false);
    }

    // ======================== AAVE HELPERS ========================

    function _repayAllDebt() internal {
        uint256 debt = debtUsdc.balanceOf(address(this));
        if (debt == 0) return;
        uint256 bal = usdc.balanceOf(address(this));
        uint256 repayAmount = bal < debt ? bal : debt;
        if (repayAmount > 0) {
            usdc.safeIncreaseAllowance(address(aavePool), repayAmount);
            aavePool.repay(address(usdc), repayAmount, 2, address(this));
            emit DebtRepaid(repayAmount);
        }
    }

    function _checkLTV() internal view {
        uint256 collateralUsd = (aWbtc.balanceOf(address(this)) * _wbtcPriceUsd()) / WBTC_DECIMALS;
        uint256 debtUsd = (debtUsdc.balanceOf(address(this)) * USD_DECIMALS) / USDC_DECIMALS;
        if (collateralUsd > 0) {
            uint256 ltvBps = (debtUsd * 10_000) / collateralUsd;
            if (ltvBps > MAX_LTV_BPS) revert LTVTooHigh(ltvBps, MAX_LTV_BPS);
        }
    }

    function _getHealthFactor() internal view returns (uint256) {
        // C7: Use real AAVE health factor instead of manual calculation
        (,,,,, uint256 hf) = aavePool.getUserAccountData(address(this));
        return hf; // AAVE returns HF with 18 decimals (1e18 = 1.0)
    }

    function _availableWbtc() internal view returns (uint256) {
        uint256 totalWbtc = aWbtc.balanceOf(address(this));
        uint256 debt = debtUsdc.balanceOf(address(this));
        if (debt == 0) return totalWbtc;

        uint256 price = _wbtcPriceUsd();
        uint256 debtUsd = (debt * USD_DECIMALS) / USDC_DECIMALS;
        uint256 minCollateralUsd = (debtUsd * 10_000) / MAX_LTV_BPS;
        uint256 minWbtc = (minCollateralUsd * WBTC_DECIMALS) / price;

        return totalWbtc > minWbtc ? totalWbtc - minWbtc : 0;
    }

    function _tvlInUsdc6() internal view returns (uint256) {
        uint256 tvlWbtc = this.totalAssets();
        uint256 price = _wbtcPriceUsd();
        // tvl(8dec) * price(8dec) / 1e10 → 6dec USDC
        return (tvlWbtc * price) / 1e10;
    }

    // ======================== VIEWS ========================

    function _wbtcPriceUsd() internal view returns (uint256) {
        return aaveOracle.getAssetPrice(address(wbtc));
    }

    function currentPrice() external view override returns (uint256) {
        return _wbtcPriceUsd();
    }

    /// @notice Total assets in WBTC terms
    function totalAssets() external view override returns (uint256) {
        uint256 aaveWbtc = aWbtc.balanceOf(address(this));
        uint256 price = _wbtcPriceUsd();

        uint256 debt = debtUsdc.balanceOf(address(this));
        uint256 debtInWbtc = 0;
        if (price > 0 && debt > 0) {
            debtInWbtc = (debt * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price);
        }

        int256 gmxPnlWbtc = _gmxPositionValueWbtc(price);

        // Aevo puts value
        uint256 aevoPutsWbtc = 0;
        if (address(aevoAdapter) != address(0) && price > 0) {
            uint256 putsUsdc = aevoAdapter.totalPutValue();
            aevoPutsWbtc = (putsUsdc * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price);
        }

        uint256 freeWbtc = wbtc.balanceOf(address(this));
        uint256 freeUsdc = usdc.balanceOf(address(this));
        uint256 freeUsdcInWbtc = 0;
        if (price > 0 && freeUsdc > 0) {
            freeUsdcInWbtc = (freeUsdc * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price);
        }

        uint256 base = aaveWbtc > debtInWbtc ? aaveWbtc - debtInWbtc : 0;
        uint256 total = base + freeWbtc + freeUsdcInWbtc + aevoPutsWbtc;

        if (gmxPnlWbtc >= 0) {
            total += uint256(gmxPnlWbtc);
        } else {
            uint256 loss = uint256(-gmxPnlWbtc);
            total = total > loss ? total - loss : 0;
        }

        return total;
    }

    function _gmxPositionValueWbtc(uint256 price) internal view returns (int256) {
        int256 totalPnl;
        if (price == 0) return 0;

        for (uint256 i = 0; i < shorts.length; i++) {
            if (!shorts[i].active) continue;

            IGMXReader.PositionInfo memory info = gmxReader.getPosition(
                gmxDataStore, shorts[i].gmxPositionKey
            );

            int256 pnlWbtc = (info.unrealizedPnl * int256(WBTC_DECIMALS))
                / (int256(price) * int256(GMX_DECIMALS / USD_DECIMALS));
            totalPnl += pnlWbtc;

            if (info.collateralAmount > 0) {
                totalPnl += int256(
                    (info.collateralAmount * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price)
                );
            }
        }
        return totalPnl;
    }

    function activeShortCount() external view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < shorts.length; i++) {
            if (shorts[i].active) count++;
        }
        return count;
    }

    function totalShorts() external view returns (uint256) {
        return shorts.length;
    }

    /// @notice Get current allocation percentages
    function getAllocation() external view returns (uint256 wbtcPct, uint256 bufferPct, uint256 hedgePct) {
        return _getAllocationPcts();
    }

    /// @notice Get current health factor
    function getHealthFactor() external view returns (uint256) {
        return _getHealthFactor();
    }

    // ======================== ADMIN ========================

    function setAevoAdapter(AevoAdapter newAdapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit AevoAdapterUpdated(address(aevoAdapter), address(newAdapter));
        aevoAdapter = newAdapter;
    }

    function setDexRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit DexRouterUpdated(address(dexRouter), newRouter);
        dexRouter = ICamelotRouter(newRouter);
    }

    // ======================== RECEIVE ETH ========================
    receive() external payable {}
}
