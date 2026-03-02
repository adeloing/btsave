// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategyOnChain } from "./interfaces/IStrategyOnChain.sol";
import { IAavePool, IAaveOracle, IAToken, IVariableDebtToken } from "./interfaces/IAaveV3.sol";
import { IGMXExchangeRouter, IGMXReader, IOrderCallbackReceiver } from "./interfaces/IGMXV2.sol";
import { AevoAdapter } from "./AevoAdapter.sol";

/**
 * @title StrategyOnChain — Full On-Chain Arbitrum (V1)
 * @notice Manages WBTC on AAVE V3 (supply/borrow) + GMX V2 BTC short perps as hedge.
 *         Implements IOrderCallbackReceiver for async GMX order lifecycle.
 *
 * Architecture:
 *   - WBTC supplied to AAVE as collateral
 *   - USDC borrowed from AAVE → used as GMX short collateral
 *   - Short BTC-PERP opened on GMX V2 as hedge
 *   - OTM puts via AevoAdapter for additional downside protection
 *   - On new ATH → close all shorts (async via keeper) + close all puts, enter CLOSING phase
 *
 * State machine:
 *   IDLE → HEDGED (shorts open) → CLOSING (close orders pending) → IDLE
 *
 * Safety bounds:
 *   - Max 5% TVL per short
 *   - Max 50% AAVE LTV
 *   - Max 10% ATH jump per update
 *   - 1% max slippage on GMX orders
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
    bytes32 public immutable gmxMarketKey;       // BTC-USD market on GMX V2
    address public immutable gmxOrderVault;

    IERC20 public immutable wbtc;
    IERC20 public immutable usdc;
    IAToken public immutable aWbtc;
    IVariableDebtToken public immutable debtUsdc;

    // ======================== AEVO (PUTS) ========================
    AevoAdapter public aevoAdapter;

    // ======================== CONSTANTS ========================
    uint256 public constant MAX_SHORT_SIZE_BPS  = 500;   // max 5% TVL per single short
    uint256 public constant MAX_ATH_DELTA_BPS   = 1000;  // max 10% ATH jump per update
    uint256 public constant MAX_LTV_BPS         = 5000;  // max 50% AAVE LTV utilisation
    uint256 public constant SLIPPAGE_BPS        = 100;   // 1% max slippage on GMX

    uint256 private constant USD_DECIMALS  = 1e8;   // AAVE oracle precision
    uint256 private constant GMX_DECIMALS  = 1e30;  // GMX USD precision
    uint256 private constant WBTC_DECIMALS = 1e8;
    uint256 private constant USDC_DECIMALS = 1e6;

    // ======================== SHORT POSITION TRACKING ========================
    struct ShortPosition {
        bytes32 gmxPositionKey;
        uint256 sizeUsd;          // GMX 30-decimal
        uint256 collateralUsdc;
        bool active;
    }
    ShortPosition[] public shorts;
    mapping(bytes32 => uint256) public orderToShortIndex;

    // ======================== EVENTS ========================
    event ATHUpdated(uint256 oldATH, uint256 newATH);
    event PhaseChanged(Phase from, Phase to);
    event ShortOpened(uint256 indexed index, uint256 sizeUsd, uint256 collateralUsdc);
    event ShortClosed(uint256 indexed index);
    event ShortCloseInitiated(uint256 indexed index, bytes32 orderKey);
    event GMXOrderCallback(bytes32 indexed orderKey, bool executed);
    event DepositedToStrategy(uint256 amount);
    event WithdrawnFromStrategy(uint256 amount, address to);
    event DebtRepaid(uint256 amount);
    event AevoAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    // ======================== ERRORS ========================
    error OnlyVault();
    error OnlyGMXRouter();
    error PriceDiscoveryActive();
    error ShortTooLarge(uint256 requested, uint256 max);
    error ATHDeltaTooLarge(uint256 delta);
    error LTVTooHigh(uint256 current, uint256 max);
    error InsufficientLiquidity();
    error ShortNotActive();

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

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    // ======================== VAULT INTERFACE ========================

    /// @inheritdoc IStrategyOnChain
    function deposit(uint256 amount) external override onlyVault {
        wbtc.safeTransferFrom(vault, address(this), amount);
        wbtc.safeIncreaseAllowance(address(aavePool), amount);
        aavePool.supply(address(wbtc), amount, address(this), 0);
        emit DepositedToStrategy(amount);
    }

    /// @inheritdoc IStrategyOnChain
    function withdraw(uint256 amount, address to) external override onlyVault returns (uint256) {
        uint256 available = _availableWbtc();
        if (amount > available) revert InsufficientLiquidity();
        uint256 received = aavePool.withdraw(address(wbtc), amount, to);
        emit WithdrawnFromStrategy(received, to);
        return received;
    }

    // ======================== ATH MANAGEMENT ========================

    /// @notice Keeper updates ATH. If new ATH while hedged → initiate close of all shorts.
    function updateATH(uint256 newPrice) external onlyRole(KEEPER_ROLE) {
        if (newPrice <= currentATH) return;

        // Safety: cap max single jump
        if (currentATH > 0) {
            uint256 delta = ((newPrice - currentATH) * 10_000) / currentATH;
            if (delta > MAX_ATH_DELTA_BPS) revert ATHDeltaTooLarge(delta);
        }

        uint256 oldATH = currentATH;
        currentATH = newPrice;
        emit ATHUpdated(oldATH, newPrice);

        // If hedged → enter CLOSING phase (keeper must then call closeShort for each)
        if (phase == Phase.HEDGED) {
            _enterClosingPhase();
        }
    }

    // ======================== OPEN SHORT ========================

    /// @notice Open a short BTC position on GMX V2. Borrows USDC from AAVE.
    /// @param sizeUsd GMX 30-decimal size in USD
    /// @param collateralUsdc USDC amount (6 decimals) to borrow and use as collateral
    function openShort(
        uint256 sizeUsd,
        uint256 collateralUsdc
    ) external payable onlyRole(KEEPER_ROLE) {
        if (phase == Phase.CLOSING) revert PriceDiscoveryActive();

        // Bound: max 5% TVL per short
        uint256 tvlWbtc = this.totalAssets();
        uint256 price = _wbtcPriceUsd();
        uint256 tvlUsd30 = tvlWbtc * price * (GMX_DECIMALS / USD_DECIMALS) / WBTC_DECIMALS;
        uint256 maxSize = (tvlUsd30 * MAX_SHORT_SIZE_BPS) / 10_000;
        if (sizeUsd > maxSize) revert ShortTooLarge(sizeUsd, maxSize);

        // Borrow USDC from AAVE (variable rate = 2)
        aavePool.borrow(address(usdc), collateralUsdc, 2, 0, address(this));

        // Validate LTV post-borrow
        _checkLTV();

        // Send collateral + execution fee to GMX
        usdc.safeIncreaseAllowance(address(gmxRouter), collateralUsdc);
        gmxRouter.sendTokens(address(usdc), gmxOrderVault, collateralUsdc);
        gmxRouter.sendWnt{value: msg.value}(gmxOrderVault, msg.value);

        // Build order: MarketIncrease short
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
                executionFee: msg.value,
                callbackGasLimit: 300_000,
                minOutputAmount: 0
            }),
            orderType: bytes32(uint256(1)),    // MarketIncrease
            decreasePositionSwapType: bytes32(0),
            isLong: false,                      // SHORT
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        bytes32 orderKey = gmxRouter.createOrder(params);

        // Track position (not active until callback confirms)
        uint256 idx = shorts.length;
        shorts.push(ShortPosition({
            gmxPositionKey: orderKey,
            sizeUsd: sizeUsd,
            collateralUsdc: collateralUsdc,
            active: false
        }));
        orderToShortIndex[orderKey] = idx;

        if (phase == Phase.IDLE) {
            phase = Phase.HEDGED;
            emit PhaseChanged(Phase.IDLE, Phase.HEDGED);
        }

        emit ShortOpened(idx, sizeUsd, collateralUsdc);
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

        // Close all Aevo puts on ATH reset
        if (address(aevoAdapter) != address(0)) {
            try aevoAdapter.closeAllPuts() {} catch {}
        }
    }

    /// @notice Keeper closes one short at a time (each needs ETH for GMX execution fee)
    function closeShort(uint256 index) external payable onlyRole(KEEPER_ROLE) {
        ShortPosition storage pos = shorts[index];
        if (!pos.active) revert ShortNotActive();

        gmxRouter.sendWnt{value: msg.value}(gmxOrderVault, msg.value);

        uint256 price = _wbtcPriceUsd();
        uint256 acceptablePrice30 = price * (GMX_DECIMALS / USD_DECIMALS)
            * (10_000 + SLIPPAGE_BPS) / 10_000;  // higher = worse for short close

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
            orderType: bytes32(uint256(4)),    // MarketDecrease
            decreasePositionSwapType: bytes32(0),
            isLong: false,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        bytes32 orderKey = gmxRouter.createOrder(params);
        orderToShortIndex[orderKey] = index;

        emit ShortCloseInitiated(index, orderKey);
    }

    // ======================== GMX CALLBACKS ========================

    /// @notice Called by GMX after order execution
    function afterOrderExecution(
        bytes32 key,
        bytes calldata,
        bytes calldata
    ) external override onlyGMX {
        uint256 idx = orderToShortIndex[key];
        ShortPosition storage pos = shorts[idx];

        if (!pos.active) {
            // Open order executed → activate position
            pos.active = true;
        } else {
            // Close order executed → deactivate position
            pos.active = false;
            emit ShortClosed(idx);

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

    /// @notice Called by GMX if order is cancelled
    function afterOrderCancellation(
        bytes32 key,
        bytes calldata,
        bytes calldata
    ) external override onlyGMX {
        uint256 idx = orderToShortIndex[key];
        ShortPosition storage pos = shorts[idx];

        if (!pos.active) {
            // Open was cancelled → clean up
            pos.sizeUsd = 0;
            pos.collateralUsdc = 0;
        } else {
            // Close was cancelled → still active, decrement pending
            if (pendingCloseOrders > 0) pendingCloseOrders--;
        }
        emit GMXOrderCallback(key, false);
    }

    /// @notice Called by GMX if order is frozen
    function afterOrderFrozen(
        bytes32 key,
        bytes calldata,
        bytes calldata
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

    // ======================== VIEWS ========================

    function _wbtcPriceUsd() internal view returns (uint256) {
        return aaveOracle.getAssetPrice(address(wbtc)); // 8 decimals
    }

    /// @inheritdoc IStrategyOnChain
    function currentPrice() external view override returns (uint256) {
        return _wbtcPriceUsd();
    }

    /// @inheritdoc IStrategyOnChain
    /// @notice Total assets in WBTC terms = AAVE collateral - debt + GMX PnL + free balances
    function totalAssets() external view override returns (uint256) {
        uint256 aaveWbtc = aWbtc.balanceOf(address(this));
        uint256 price = _wbtcPriceUsd();

        // Subtract AAVE USDC debt (→ WBTC equivalent)
        uint256 debt = debtUsdc.balanceOf(address(this));
        uint256 debtInWbtc = 0;
        if (price > 0 && debt > 0) {
            debtInWbtc = (debt * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price);
        }

        // GMX short positions PnL
        int256 gmxPnlWbtc = _gmxPositionValueWbtc(price);

        // Free token balances
        uint256 freeWbtc = wbtc.balanceOf(address(this));
        uint256 freeUsdc = usdc.balanceOf(address(this));
        uint256 freeUsdcInWbtc = 0;
        if (price > 0 && freeUsdc > 0) {
            freeUsdcInWbtc = (freeUsdc * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price);
        }

        // Aevo puts value (USDC → WBTC)
        uint256 aevoPutsWbtc = 0;
        if (address(aevoAdapter) != address(0) && price > 0) {
            uint256 putsUsdc = aevoAdapter.totalPutValue(); // 6 decimals
            aevoPutsWbtc = (putsUsdc * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price);
        }

        // Sum
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

    /// @dev Aggregate PnL + collateral value of all active GMX shorts, in WBTC
    function _gmxPositionValueWbtc(uint256 price) internal view returns (int256) {
        int256 totalPnl;
        if (price == 0) return 0;

        for (uint256 i = 0; i < shorts.length; i++) {
            if (!shorts[i].active) continue;

            IGMXReader.PositionInfo memory info = gmxReader.getPosition(
                gmxDataStore,
                shorts[i].gmxPositionKey
            );

            // PnL: 30-decimal USD → WBTC
            int256 pnlWbtc = (info.unrealizedPnl * int256(WBTC_DECIMALS))
                / (int256(price) * int256(GMX_DECIMALS / USD_DECIMALS));
            totalPnl += pnlWbtc;

            // Collateral value: USDC → WBTC
            if (info.collateralAmount > 0) {
                totalPnl += int256(
                    (info.collateralAmount * USD_DECIMALS * WBTC_DECIMALS) / (USDC_DECIMALS * price)
                );
            }
        }

        return totalPnl;
    }

    /// @notice Number of currently active shorts
    function activeShortCount() external view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < shorts.length; i++) {
            if (shorts[i].active) count++;
        }
        return count;
    }

    /// @notice Total shorts ever created
    function totalShorts() external view returns (uint256) {
        return shorts.length;
    }

    // ======================== RECEIVE ETH ========================
    // ======================== AEVO ADAPTER MANAGEMENT ========================

    function setAevoAdapter(AevoAdapter newAdapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit AevoAdapterUpdated(address(aevoAdapter), address(newAdapter));
        aevoAdapter = newAdapter; // address(0) = disable puts
    }

    // ======================== RECEIVE ETH ========================
    receive() external payable {} // GMX execution fee refunds
}
