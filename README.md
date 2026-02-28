# BTSAVE ⚡

## Turbo Paper Boat (TPB) — Hybrid ZERO-LIQ BTC Accumulator

> Version 2 — 28 février 2026
> Répartition **82/15/3** · NAV-Based Token · Gnosis Safe + LSM · L1 Ethereum
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
- [Sécurité & LSM](#sécurité--lsm)
- [Infrastructure](#infrastructure)
- [Dashboard & Monitoring](#dashboard--monitoring)

---

## Philosophie

BTSAVE transforme chaque baisse du BTC en accumulation nette permanente, avec un risque de liquidation strictement nul.

**Principe** : à chaque nouvel ATH, on ne vend que la portion minimale du WBTC accumulé pour rembourser 100 % de la dette AAVE. Tout le reste est du BTC net gagné. Les profits Deribit (carry contango + puts) sont du bonus pur.

**Pour l'utilisateur** : déposer du WBTC → recevoir des TPB tokens → attendre → recevoir des TPB bonus à chaque nouvel ATH → redeem en WBTC.

---

## TPB Token

**Turbo Paper Boat (TPB)** — ERC-20, 8 decimals (= satoshis).

| Propriété | Détail |
|-----------|--------|
| **Mint** | NAV-based (ERC-4626 style) |
| **Premier dépôt** | 1 WBTC = 1e8 TPB (1:1) |
| **Dépôts suivants** | `shares = (wbtcAmount × totalSupply) / totalAssets` |
| **Transferable** | Oui — libre trade sur DEX dès le mint |
| **Redeem** | Burn TPB → WBTC pro-rata, **uniquement step 0 (post-ATH, pre-lock)** |
| **Pas de retrait mid-cycle** | Feature, pas bug — force la conviction |

### NAV-Based Minting

Le prix d'entrée reflète la valeur réelle du vault. Si la stratégie a généré 20% de gains, un nouveau déposant reçoit proportionnellement moins de TPB — **les early holders ne sont jamais dilués**.

```
totalAssets = WBTC dans le vault + WBTC déployé dans la stratégie (Safe)
sharePrice  = totalAssets / totalSupply
```

### Trading sur DEX

Le TPB est librement tradable. En bear market, il tradera probablement sous le NAV sur Uniswap — c'est du alpha gratuit pour les contrarians qui achètent le dip. Ceux qui bradent en plein crash financent ceux qui tiennent.

---

## Architecture Smart Contracts

```
┌──────────────────────────────────────────────────┐
│                  VaultTPB.sol                      │
│          ERC-20 TPB Token + Vault Logic            │
│                                                    │
│  deposit(WBTC) → mint TPB (NAV-based)             │
│  redeem(TPB) → burn + WBTC pro-rata (step 0)     │
│  setAutoRedeem(bps) → auto à chaque ATH           │
│  endCycleAndReward() → mint bonus TPB pro-rata    │
│                                                    │
│  Pending Pool → rebalance hebdo ou seuil 2%       │
│  Lock/Unlock → ATH-5% trigger                     │
└───────────────────┬──────────────────────────────┘
                    │ owns / controls
┌───────────────────▼──────────────────────────────┐
│           LimitedSignerModule v3 (LSM)            │
│              Gnosis Safe Module                    │
│                                                    │
│  19 règles on-chain (R1-R19)                      │
│  Multi-bot consensus (2/3 minimum)                │
│  Kill switch (2/2 Safe owners only)               │
│  HF threshold: 1.55                               │
│  Proposal TTL: 30 min                             │
│  Daily volume caps (borrow + swap)                │
│  Target/selector whitelisting                     │
│  Code hash pinning (R9)                           │
└───────────────────┬──────────────────────────────┘
                    │ executes via
┌───────────────────▼──────────────────────────────┐
│              Gnosis Safe (2/2 multisig)           │
│                                                    │
│  Owners: xou + mael (humains)                     │
│  Bots = NOT owners, execute via Module only       │
│  Threshold 2/2 pour kill switch + admin           │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│               NFTBonus.sol (ERC-1155)              │
│                                                    │
│  4 tiers: Bronze / Silver / Gold / Platinum       │
│  Bonus multiplier sur les rewards TPB             │
│  Trading encouragé — vérifié à l'instant T        │
│  1 NFT / cycle / utilisateur (min 100 USDC)      │
└──────────────────────────────────────────────────┘
```

### Répartition du capital

| Compartiment | % | Rôle |
|---|---|---|
| WBTC AAVE V3 | 82% | Collateral principal |
| USDC AAVE V3 | 15% | Buffer anti-liquidation |
| USDC Deribit | 3% | Margin shorts + puts |

---

## Cycle de vie

Un cycle **commence et se termine uniquement à un nouvel ATH ratcheté**.

```
1. Nouvel ATH détecté (prix > currentATH)
   │
   ├─ Clôturer tous les shorts Deribit
   ├─ Calculer performance nette du cycle (en sats)
   ├─ Rembourser 100% dette AAVE (vente minimale WBTC)
   ├─ endCycleAndReward() :
   │   ├─ Mint bonus TPB pro-rata aux holders
   │   ├─ Appliquer multiplicateur NFT
   │   ├─ Exécuter auto-redeems
   │   └─ Reset cycle (nouveau ATH, step 0, unlock)
   ├─ Rééquilibrer 82/15/3
   └─ Nouveau cycle
   
2. Prix atteint ATH - 5%
   │
   └─ lockVault() : redemptions bloquées
   
3. Prix descend par paliers de 5%
   │
   ├─ advanceStep() : step++
   ├─ Short BTC (Deribit sell stop auto)
   ├─ Borrow USDC sur AAVE
   ├─ Swap → WBTC (DeFiLlama)
   └─ WBTC accumulé en collateral
```

### Variables du cycle (exemple ATH $126k)

| Variable | Formule | Valeur |
|----------|---------|--------|
| `step_size` | ATH × 5% | $6,300 |
| `borrow_per_step` | WBTC_start × 3,200 | 12,480 USDC |
| `short_per_step` | WBTC_start × 0.0244 | 0.095 BTC |

---

## Stratégie d'accumulation

### À chaque palier de baisse (−5%)

**Automatisé (Deribit)** :
- Stop Market SELL se déclenche (short grid)
- Carry contango/funding toutes les 8h

**Via LSM + Safe** :
1. Borrow USDC sur AAVE V3
2. Swap USDC → WBTC via DeFiLlama (meilleur agrégateur L1)
3. WBTC déposé en collateral AAVE
4. Vérification HF post-opération

### À la hausse

Aucune action. Shorts restent ouverts pour le contango.

### Gestion par Health Factor

```
HF ≥ 1.55    ✅ Accumulation normale
HF 1.40–1.55 👁️ Monitor renforcé
HF < 1.40    🛑 STOP emprunts
HF ≤ 1.30    ⚠️ Vendre 50% puts → rembourser 25% dette
HF ≤ 1.25    🔶 Vendre puts restants → rembourser 40% dette
HF < 1.15    🚨 Vendre tout → rembourser max
```

### Protection Puts OTM

Couverture automatique du WBTC accumulé, financée par le carry contango.

| WBTC Extra | Couverture | Strike |
|-----------|------------|--------|
| ≥ 6% | 60% du extra | −26% à −28% OTM |
| ≥ 14% | 85% du extra | −23% à −24% OTM |
| ≥ 24% | 100% du extra | −21% OTM |

---

## Mécaniques Utilisateur

### Deposit

```solidity
vault.deposit(wbtcAmount)
// → WBTC transféré au vault
// → TPB mintés (NAV-based)
// → WBTC en pending pool
```

### Redeem (step 0 uniquement)

```solidity
vault.redeem(tpbAmount)
// → TPB brûlés
// → WBTC restitués pro-rata de totalAssets
// Bloqué si step > 0 ou vault locked
```

### Auto-Redeem

```solidity
vault.setAutoRedeem(5000) // 50% en BPS
// → Exécuté automatiquement à chaque fin de cycle (nouvel ATH)
// → Pro-rata si demande > liquidité disponible
```

### Pending Pool & Rebalancing

Les dépôts ne sont pas immédiatement déployés dans la stratégie :
- **Rebalance hebdomadaire** : keeper déploie le pending pool vers le Safe
- **Ou seuil 2%** : si pending > 2% du TVL déployé, rebalance déclenchable
- Le WBTC part au Safe pour être réparti en 82/15/3

### Preview

```solidity
vault.previewRedeem(tpbAmount) // → combien de WBTC on recevrait
vault.totalAssets()            // → WBTC vault + WBTC Safe
```

---

## NFT Bonus System

**ERC-1155** — 4 tiers, attribués en fin de cycle.

| Tier | Conditions | Multiplicateur ≈ |
|------|-----------|-------------------|
| 🥉 Bronze | Participation au cycle | 1.05x |
| 🥈 Silver | Holding significatif | 1.15x |
| 🥇 Gold | Holding important | 1.5x-2x |
| 💎 Platinum | Top holder | 2.5x+ |

**Règles** :
- 1 NFT par cycle par utilisateur (min 100 USDC)
- NFT du cycle en cours exclu du bonus (sauf cycle 1)
- Vérification de la collection à l'instant T (fin de cycle)
- **Trading encouragé** : acheter/vendre des NFTs pour optimiser sa collection
- Pas de mémoire permanente — seul le `balanceOf` au moment du reward compte
- Le bonus s'applique comme multiplicateur sur le reward TPB minté

---

## Sécurité & LSM

### Defense in Depth

```
Bots off-chain (observe + filter)
        │
        ▼
LimitedSignerModule v3 (on-chain judge, 19 rules)
        │
        ▼
Gnosis Safe 2/2 (human final authority)
```

### 19 Règles LSM (R1-R19)

| Règle | Description |
|-------|-------------|
| R1 | Seuls les keepers/bots autorisés |
| R2-R3 | Whitelisting targets + selectors |
| R4 | Kill switch check |
| R5 | Gas price < plafond (80 gwei, auto-reset) |
| R6 | Nonce séquentiel |
| R7 | `approve()` bloqué sauf spenders whitelistés |
| R8 | Pas de `delegatecall` |
| R9 | Code hash pinning (1inch, AAVE Pool, Oracle) |
| R10-R11 | Pas de `value` (ETH), data non-vide |
| R12 | Daily tx limit |
| R13-R14 | Daily volume caps (borrow + swap) |
| R15 | HF pre-check ≥ 1.55 (bypass pour repay) |
| R16-R17 | Multi-bot consensus (2/3 min) |
| R18 | Proposal TTL (30 min, auto-expire) |
| R19 | `executeIfReady` restricted to keepers |

### Kill Switch

- Activable uniquement par les 2 Safe owners (2/2 multisig)
- Bloque **toutes** les opérations via Module
- Aucun bot ne peut désactiver

### Risque de liquidation : 0%

1. Buffer 15% USDC (ne fluctue pas avec BTC)
2. Règles HF strictes (stop à 1.40, repay dès 1.30)
3. Puts OTM automatiques
4. Exécution < 1h (L1 Ethereum direct)

---

## Infrastructure

### Stack

```
contracts/
├── src/
│   ├── VaultTPB.sol              # Vault + ERC-20 TPB token
│   ├── LimitedSignerModule.sol   # LSM v3 (Gnosis Safe Module)
│   ├── NFTBonus.sol              # ERC-1155 bonus NFTs
│   └── MockContracts.sol         # Mocks pour tests
├── test/
│   ├── VaultTPB.t.sol            # 36 tests
│   └── LimitedSignerModule.t.sol # 30 tests
└── script/
    └── DeployPhase1.s.sol        # Déploiement Sepolia

bot-observe/
├── index.js                      # Bot observer (Phase 1)
└── keeper-test.js                # Tests d'intégration Sepolia

server.js                         # Dashboard Express
alert-telegram-bridge.js          # Prometheus → Telegram
```

### Tests

```bash
# 66 tests total (36 VaultTPB + 30 LSM)
cd contracts && forge test -vv
```

### Déploiement (Sepolia)

Dernières adresses (DeployAll2) :
- Vault: `0xbB5AA31D849860e5A6D3b288DD33177667115678`
- Safe: `0x6727...e8`
- NFT: `0x208B...d7`
- Deployer/Keeper: `0x490CE9212cf474a5A73936a8d25b5Ef46751a58f`

---

## Dashboard & Monitoring

### Dashboard Web

Interface mobile-first : prix BTC, step actuel, HF, collateral AAVE, positions Deribit, grid gains, recommandations.

**Accès** : `https://ratpoison2.duckdns.org/hedge/`

### Grafana

Métriques Prometheus : tx proposées/exécutées/rejetées, HF live, gas, volume daily, bot latency, rejections par règle.

**Accès** : `https://ratpoison2.duckdns.org/grafana/d/lsm-phase1/`

### Alerting

Prometheus → Alertmanager → Telegram Bridge → @BTSave_bot

---

## Business

### Associés
- **xou** — Architecture, stratégie, développement
- **Mael** — Crypto ops, expérience tokens Solana

### Token Vision

Token "anti-shitcoin" adossé à du BTC réel. Plus le marché crashe, plus on accumule pas cher. Trois sources de revenus :
1. Accumulation BTC (gains de cycle)
2. Grid gains (contango + shorts)
3. Trading du propre token (arbitrage NAV)

### Roadmap

- [x] Phase 1 : Observe-only bot + monitoring
- [x] Phase 2 : Smart contracts (VaultTPB v2 + LSM v3 + NFTBonus)
- [ ] Phase 3 : Déploiement mainnet + audit
- [ ] Phase 4 : Token public + DEX listing

---

*BTSAVE — Parce que chaque dip est une opportunité, pas un risque.* ⚡
