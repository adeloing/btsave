# BTSAVE — Finale Ultime Strategy

**Hybrid ZERO-LIQ Aggressive Accumulator with Health Factor Management**

Version: Finale Ultime - Répartition 79/18/3 - HF Only - Puts Auto - L1 ETH  
Date: 18 février 2026  
Status: **Version finale verrouillée**

## 🎯 Strategy Overview

BTSAVE Finale Ultime is a sophisticated Bitcoin accumulation strategy that combines:
- **Zero liquidation risk** through Health Factor (HF) management  
- **Aggressive accumulation** during market downturns
- **Delta-neutral hedging** via Deribit futures
- **Automated puts protection** for downside risk management
- **100% on-chain execution** on Ethereum Layer 1

### Core Philosophy

The strategy maximizes net WBTC holdings at each new all-time high (ATH) by:
1. **Selling only what's necessary** to repay 100% of debt
2. **Keeping all accumulated WBTC** as permanent net gains
3. **Generating bonus profits** from Deribit carry and puts trading
4. **Maintaining zero liquidation risk** through strict HF management

## 🔄 Cycle Mechanics

### ATH Reset System
- **Cycle start**: Triggered only at new ATH
- **Fixed parameters**: All quantities and thresholds set at cycle beginning
- **Cycle end**: When BTC reaches new ATH → close all positions, repay debt, keep accumulated WBTC

### Initial Allocation (79/18/3)
- **79% WBTC**: Aggressive collateral for maximum accumulation potential
- **18% USDC AAVE**: Safety buffer for HF management  
- **3% USDC Deribit**: Margin for delta-neutral futures positions

## 📊 Health Factor Management System

**Revolutionary shift**: 100% Health Factor based rules (no more price-based thresholds)

### HF Thresholds & Actions

| Health Factor | Zone | Actions |
|---------------|------|---------|
| **HF ≥ 1.50** | 🟢 Normal Accumulation | Continue borrowing at every 5% price step |
| **HF 1.40-1.50** | 🟡 Enhanced Monitor | Reinforced monitoring, borrowing still allowed |
| **HF < 1.40** | 🔴 Stop Borrowing | **HALT** all new borrowing immediately |
| **HF = 1.30** | 🟠 Put Monetization 1 | Sell 50% puts → repay 25% debt |
| **HF = 1.25** | 🔴 Put Monetization 2 | Sell remaining puts → repay 40% debt |
| **HF < 1.15** | 🚨 Emergency | Sell all positions → repay maximum debt |

### Key Advantages
- **Real-time risk assessment** vs static price percentages
- **Dynamic adaptation** to changing collateral values
- **Zero liquidation risk** with HF always >1.15 in worst case
- **Continues accumulation** as long as HF permits (not price-limited)

## 🛡️ Automated Puts OTM Protection

### Dynamic Coverage Rules

Protection automatically activates based on:
- **WBTC_extra_percent**: `(WBTC_total - WBTC_start) / WBTC_start × 100`
- **Current Health Factor**

| Condition | Coverage | Strike | Expiry |
|-----------|----------|---------|--------|
| WBTC_extra ≥6% + HF ≥1.68 | 60% extra WBTC | -26% to -28% OTM | 45-60 days |
| WBTC_extra ≥14% + HF ≥1.56 | 85% extra WBTC | -23% to -24% OTM | 35-50 days |
| WBTC_extra ≥24% (any HF >1.35) | 100% extra WBTC | -21% OTM | 30-45 days |

### HF-Based Adjustments
- **HF 1.55-1.70**: Increase coverage +15%, tighten strikes by 2%
- **HF 1.40-1.55**: Jump to 100% coverage, -20% strikes
- **HF <1.40**: Stop new puts purchases → monetization mode only

## 🏗️ Platform Architecture

### AAVE V3 (Ethereum L1)
- **Collateral**: WBTC (LTV 73%, Liquidation Threshold 78%)
- **Borrowing**: USDC/USDT for accumulation
- **Safety**: 18% USDC buffer for HF stability

### Deribit
- **Carry generation**: Delta-neutral BTC-PERP shorts
- **Put protection**: OTM puts for accumulated WBTC
- **Automatic stops**: Market orders at each 5% price step

### DeFiLlama Integration
- **Swaps**: All USDC→WBTC conversions for best rates
- **On-chain only**: No custodial risks, full transparency

## 📈 Step-by-Step Execution

### 5% Price Steps Down
1. **Automatic Deribit**: SELL STOP market order triggers
2. **Manual AAVE**: Borrow predefined USDC amount
3. **Manual Swap**: DeFiLlama USDC → aEthWBTC conversion
4. **HF Check**: Verify HF remains above thresholds
5. **Put Assessment**: Check if new puts protection needed

### Price Recovery
- **Automatic closure**: BUY STOP orders close shorts on upward moves
- **Profit accumulation**: Contango carry + short profits
- **Fund transfers**: Excess Deribit USDC → AAVE (weekly)

## 🔧 Dashboard & Simulation

### Production Dashboard (`/`)
- **Real-time monitoring**: Live HF, positions, prices
- **Action alerts**: HF-based recommendations  
- **Platform integration**: AAVE + Deribit data
- **Mobile-optimized**: Touch-friendly interface

### Simulation Engine (`/simu.html`)
- **HF-based logic**: Test strategy with various scenarios
- **Step simulation**: Visualize accumulation progression
- **Risk analysis**: Stress-test different market conditions
- **Strategy validation**: Verify HF thresholds and actions

## 🔐 Security & Access

### Authentication System
- **Admin**: Full control, position management, alerts
- **Read-only**: Monitoring access, no trading functions  
- **Telegram integration**: Real-time notifications and updates

### Risk Controls
- **HF monitoring**: Continuous health factor tracking
- **Liquidation buffer**: Multiple safety layers (18% USDC + puts + <1hr execution)
- **Manual overrides**: Admin can intervene at any threshold
- **Audit trails**: Complete logging of all decisions and actions

## 🚀 Getting Started

### Prerequisites
- Node.js environment
- AAVE V3 position on Ethereum L1
- Deribit account with API access
- Initial allocation in 79/18/3 ratio

### Installation
```bash
git clone https://github.com/adeloing/btsave
cd btsave
npm install
npm start
```

### Configuration
1. Set up API keys for AAVE and Deribit
2. Configure initial collateral amounts
3. Set Health Factor monitoring thresholds
4. Enable Telegram notifications

## 📚 Strategy Evolution

**Finale Ultime** represents the culmination of multiple strategy iterations:
- **V1**: Price-based percentage thresholds
- **V2**: Hybrid price + HF monitoring  
- **V3**: Full HF-based management (this version)

This version is **final and locked** as of February 18, 2026. The strategy is designed to be reusable indefinitely across all market cycles.

---

*Built with ❤️ for maximum Bitcoin accumulation and zero liquidation risk*