# BTSAVE ⚡

## Turbo Paper Boat (TPB) — Full On-Chain BTC Accumulator (Arbitrum)

> Version 3 — 2 mars 2026
> Répartition **82/15/3** · ERC-4626 Vault · Timelock + Guardian · Full On-Chain Arbitrum
>
> **BTSAVE** = l'entreprise · **Turbo Paper Boat (TPB)** = le produit (token)

---

## Sommaire

- [Philosophie](#philosophie)
- [TPB Token](#tpb-token)
- [Architecture Smart Contracts](#architecture-smart-contracts)
- [Cycle de vie](#cycle-de-vie)
- [Stratégie d'accumulation](#stratégie-daccumulation)
- [Mécaniques Utilisateur](#mécaniques-utilisateur)
- [NFT Bonus System](#nft-bonus-system)
- [Sécurité](#sécurité)
- [Infrastructure](#infrastructure)
- [Dashboard & Monitoring](#dashboard--monitoring)

---

## Philosophie

BTSAVE transforme chaque baisse du BTC en accumulation nette permanente, avec un risque de liquidation strictement nul.

**Principe** : à chaque nouvel ATH, on clôture tous les hedges (GMX shorts + Aevo puts), on rembourse 100 % de la dette AAVE, et tout le WBTC restant est du gain net. Les profits de shorts GMX et puts Aevo sont du bonus pur.

**Pour l'utilisateur** : déposer du WBTC → recevoir des TPB tokens → attendre → les TPB prennent de la valeur à chaque cycle → redeem en WBTC quand on veut.

---

## TPB Token

**Turbo Paper Boat (TPB)** — ERC-20 / ERC-4626 Vault Shares, 8 decimals.

| Propriété | Détail |
|-----------|--------|
| **Standard** | ERC-4626 (OpenZeppelin) |
| **Mint** | NAV-based (anti-dilution automatique) |
| **Entry Fee** | 2% base (5% near ATH), réduit par NFTBonus |
| **Exit Fee** | Progressif: 2% (<7j), 1% (<30j), 0.5% (<90j), 0% (≥90j) + 1% bonus drawdown |
| **Transferable** | Oui — libre trade sur DEX |
| **Redeem** | À tout moment (exit fee applicable) |

---

## Architecture Smart Contracts

```
┌──────────────────────────────────────────────────┐
│          TurboPaperBoatVault.sol (ERC-4626)       │
│                                                    │
│  deposit(WBTC) → mint TPB (fee deducted)          │
│  withdraw/redeem → exit fee (time-based + drawdown)│
│  pause/unpause → Guardian / Timelock              │
│  setStrategy / setTreasury / setNFTBonus → Admin  │
└───────────────────┬──────────────────────────────┘
                    │ delegates capital to
┌───────────────────▼──────────────────────────────┐
│           StrategyOnChain.sol                      │
│       AAVE V3 + GMX V2 + Aevo + Camelot          │
│                                                    │
│  State Machine: IDLE → HEDGED → CLOSING → IDLE   │
│  AAVE V3: supply WBTC collateral, borrow USDC    │
│  GMX V2: split shorts (profit-taking + insurance) │
│  Aevo puts: P1 60% ATH + P2 85% ATH              │
│  Camelot DEX: USDC ↔ WBTC swaps                  │
│  Cash flow: HF-based priority (repay vs accumulate)│
│  Rebalancing: ±3% drift OR every 14 days          │
│  ATH update → full unwind + cycle reset           │
└───────────────────┬──────────────────────────────┘
                    │
     ┌──────────────┼──────────────┐
     ▼              ▼              ▼
┌──────────┐ ┌──────────────┐ ┌──────────────────┐
│AevoAdapter│ │ AAVE V3 Pool │ │ GMX V2 Exchange  │
│ (Puts)    │ │ (Arbitrum)   │ │ Router (Arbitrum)│
└──────────┘ └──────────────┘ └──────────────────┘

┌──────────────────────────────────────────────────┐
│               NFTBonus.sol (ERC-1155)              │
│  4 tiers: Bronze / Silver / Gold / Platinum       │
│  Bonus = Base × TierQuality × Completion          │
│  Reduces entry fees on vault deposit              │
└──────────────────────────────────────────────────┘
```

### Répartition du capital

| Compartiment | % | Rôle |
|---|---|---|
| WBTC AAVE V3 | 82% | Collateral principal |
| USDC Buffer | 15% | Anti-liquidation + cash flow |
| Hedging | 3% | 2% GMX V2 shorts + 1% Aevo puts |

---

## Cycle de vie

Un cycle commence et se termine uniquement à un nouvel ATH ratcheté.

```
1. Nouvel ATH détecté (keeper.updateATH)
   │
   ├─ Phase → CLOSING
   ├─ Clôturer tous les shorts GMX V2
   ├─ Clôturer tous les puts Aevo
   ├─ Rembourser 100% dette AAVE
   ├─ Phase → IDLE
   ├─ Reset cycle counters
   └─ Rééquilibrer 82/15/3
   
2. Prix descend (keeper.managePositions)
   │
   ├─ Open shorts GMX V2 (profit-taking + insurance)
   ├─ Open puts Aevo (P1 60% ATH + P2 85% ATH)
   ├─ Phase → HEDGED
   ├─ Manage trailing stops, profit-taking
   ├─ Auto-reopen shorts si drop -8% / -15% (max 3x)
   └─ Cash flow management (HF-based)
```

### GMX V2 Shorts — Split Architecture

| Moitié | Allocation | Clôture |
|--------|-----------|---------|
| **Profit-Taking** | 1% TVL | +12% → close 30%, +25% → 50%, +40% → 100% |
| **Insurance** | 1% TVL | Recovery -8% from bottom OR new ATH |
| **Trailing Stop** | Both | 60% of max observed profit |
| **Reopenings** | Max 3/cycle | At -8% and -15% from last open |

### Aevo Puts

| Palier | Strike | Allocation |
|--------|--------|-----------|
| P1 | 60% ATH | 0.5% TVL |
| P2 | 85% ATH | 0.5% TVL |
| Reopen | BTC < -7% ATH OR HF < 2.6 | Same allocation |
| Roll Down | +70% profit | Close + reopen lower |

---

## Stratégie d'accumulation

### Cash Flow Priority (HF-Based)

```
HF < 1.85    → 100% repay AAVE debt
HF 1.85-2.0  → 50% debt / 50% buy WBTC
HF ≥ 2.0     → Priority buy WBTC (via Camelot)
Always keep 2% TVL USDC reserve
```

### Exit Fees (Progressifs)

| Durée holding | Fee base | + Drawdown bonus |
|---------------|----------|------------------|
| < 7 jours | 2.0% | +1.0% si BTC < -10% ATH |
| 7-29 jours | 1.0% | +1.0% si BTC < -10% ATH |
| 30-89 jours | 0.5% | +1.0% si BTC < -10% ATH |
| ≥ 90 jours | 0% | — |

---

## NFT Bonus System

**ERC-1155** — 4 tiers, attribués en fin de cycle.

| Tier | Multiplicateur BPS |
|------|-------------------|
| 🥉 Bronze | 10,000 (1.0x) |
| 🥈 Silver | 12,000 (1.2x) |
| 🥇 Gold | 14,500 (1.45x) |
| 💎 Platinum | 17,500 (1.75x) |

**Bonus Formula** : `Base × TierQuality × Completion`
- Base = 1 + 0.12 × (distinct cycles in collection)
- Completion = 1.35x if holding NFT for every historical cycle
- Max multiplier = ~2.275x → entry fee reduced to ~44% of base

---

## Sécurité

### Access Control

| Rôle | Privilèges | Détenteur |
|------|-----------|-----------|
| **DEFAULT_ADMIN** | setStrategy, setTreasury, unpause, all admin | Timelock Controller |
| **GUARDIAN** | pause() (instant) | Founder EOA |
| **KEEPER** | updateATH, manage positions, rebalance | Keeper bot(s) |

### Defense in Depth

- **ReentrancyGuard** sur tous les entry points (deposit/mint/withdraw/redeem)
- **Pause** : guardian peut freeze instantanément, seul timelock peut unpause
- **LTV cap** : 50% max (vérifié on-chain après chaque borrow)
- **ATH delta cap** : max 10% jump (anti-manipulation)
- **Slippage protection** : 1% GMX, 0.5% Camelot swaps
- **Premium limits** : anti-sandwich sur puts Aevo

---

## Infrastructure

### Stack

```
contracts/
├── src/
│   ├── TurboPaperBoatVault.sol  # ERC-4626 vault + fees
│   ├── StrategyOnChain.sol      # AAVE V3 + GMX V2 + state machine
│   ├── AevoAdapter.sol          # Aevo OTM puts
│   ├── NFTBonus.sol             # ERC-1155, 4 tiers, fee discount
│   ├── interfaces/              # IAaveV3, IGMXV2, IAevo, ICamelot, IStrategyOnChain
│   └── mocks/                   # MockERC20
├── foundry.toml
└── remappings.txt

server.js                        # Dashboard Express (port 3001)
landing/                         # Site turbopaperboat.com
notifier.js                      # Telegram alerts
alert-telegram-bridge.js         # Prometheus → Telegram
```

### Build & Test

```bash
cd contracts && forge build
forge test -vv
```

---

## Dashboard & Monitoring

### Dashboard Web

Interface mobile-first : prix BTC, phase stratégie, HF AAVE, positions GMX, puts Aevo, NAV, exit fees.

**Accès** : `https://turbopaperboat.com/dashboard/`

### Alerting

Notifier → Telegram Bridge → @BTSave_bot

---

## Roadmap

- [x] Phase 1 : Observe-only bot + monitoring
- [x] Phase 2 : Smart contracts V1 (VaultTPB + LSM + NFTBonus) — Sepolia
- [x] Phase 3 : Full on-chain Arbitrum (TurboPaperBoatVault + StrategyOnChain + AevoAdapter)
- [ ] Phase 4 : Audit professionnel + tests Arbitrum testnet
- [ ] Phase 5 : Déploiement mainnet Arbitrum
- [ ] Phase 6 : Token public + DEX listing

---

*BTSAVE — Parce que chaque dip est une opportunité, pas un risque.* ⚡
