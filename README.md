# BTSAVE ⚡

## Hybrid ZERO-LIQ Aggressive Accumulator + Quarterly Contango Hedge

> Version finale verrouillée — 18 février 2026  
> Répartition **79/18/3** · Health Factor Only · Puts Auto · L1 Ethereum

---

## Sommaire

- [Philosophie](#philosophie)
- [Architecture](#architecture)
- [Cycle de vie](#cycle-de-vie)
- [Variables du cycle](#variables-du-cycle)
- [Exécution par palier](#exécution-par-palier)
- [Gestion par Health Factor](#gestion-par-health-factor)
- [Protection Puts OTM](#protection-puts-otm)
- [Équilibrages](#équilibrages)
- [Infrastructure technique](#infrastructure-technique)
- [Dashboard de production](#dashboard-de-production)
- [Simulateur](#simulateur)
- [Monitoring & Notifications](#monitoring--notifications)
- [Sécurité](#sécurité)

---

## Philosophie

BTSAVE transforme chaque baisse du BTC en accumulation nette permanente, avec un risque de liquidation strictement nul.

**Principe** : à chaque nouvel ATH, on ne vend que la portion minimale du WBTC accumulé pendant le cycle (P2) pour rembourser 100 % de la dette AAVE. Tout le reste est du BTC net gagné. Les profits Deribit (carry contango + puts) sont du bonus pur.

**Pourquoi ça marche** :
- Le BTC fait des nouveaux ATH → chaque cycle se clôture en profit net BTC
- Entre les ATH, on accumule agressivement dans les dips
- Le buffer 18 % USDC + puts OTM + exécution < 1h = liquidation impossible
- Le carry contango des shorts finance les puts → couverture quasi gratuite

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  AAVE V3 Core                   │
│              Ethereum L1 (mainnet)              │
│                                                 │
│  ┌──────────┐  ┌──────────┐                     │
│  │ aEthWBTC │  │  aEthUSDC │                    │
│  │  79 %    │  │   18 %    │  ← Collateral      │
│  └──────────┘  └──────────┘                     │
│       │                                         │
│       │  Borrow USDC → DeFiLlama → aEthWBTC    │
│       ▼        (accumulation loop)              │
│  ┌──────────┐                                   │
│  │ Debt USDC│  ← Remboursé à 100 % au reset    │
│  └──────────┘                                   │
│                                                 │
│  LTV max: 73 % · Liq Threshold: 78 %           │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│                   DERIBIT                        │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ USDC 3%  │  │ Short    │  │ Puts OTM │      │
│  │ (margin) │  │ BTC-PERP │  │ (protect) │     │
│  └──────────┘  └──────────┘  └──────────┘      │
│                                                 │
│  Sell stops grid ─── carry contango ─── puts    │
└─────────────────────────────────────────────────┘

Swaps : DeFiLlama (meilleur agrégateur L1)
```

---

## Cycle de vie

Un cycle **commence et se termine uniquement à un nouvel ATH ratcheté**.

```
Nouvel ATH détecté
    │
    ├─ Fermer tous les shorts Deribit (profits = bonus net)
    ├─ Calculer dette totale AAVE
    ├─ Vendre la portion minimale de WBTC accumulé (P2) via DeFiLlama
    │   pour générer exactement le montant USDC de remboursement
    ├─ Rembourser 100 % dette AAVE
    ├─ Conserver tout le WBTC restant → gain net permanent
    ├─ Rééquilibrer le collateral en 79/18/3
    └─ Nouveau cycle : recalculer toutes les variables
```

**Règle absolue** : on ne se couvre jamais contre la hausse. Les shorts restent ouverts pour maximiser le contango.

---

## Variables du cycle

Toutes les variables sont **fixes** dès le début du cycle. Aucun ajustement en cours de route.

| Variable | Formule | Cycle actuel (ATH $126k) |
|----------|---------|--------------------------|
| `ATH` | Prix spot au moment du reset | $126,000 |
| `WBTC_start` | Quantité WBTC dans AAVE après reset | 3.90 BTC |
| `step_size` | ATH × 0.05 | $6,300 |
| `buffer_USDC_AAVE` | WBTC_start × ATH × 0.18 | $88,452 |
| `USDC_Deribit_target` | WBTC_start × ATH × 0.03 | $14,742 |
| `borrow_per_step` | WBTC_start × 3,200 (arrondi 100) | 12,480 USDC |
| `short_per_step` | WBTC_start × 0.0244 (arrondi 3 déc.) | 0.095 BTC |

**19 paliers possibles** de l'ATH au fond (ATH − 19 × step = $6,300).

---

## Exécution par palier

À chaque franchissement de palier de 5 % **à la baisse** :

### Automatisé (Deribit)
- Stop Market SELL `short_per_step` BTC se déclenche
- Accrual contango/funding toutes les 8h

### Manuel (AAVE + DeFiLlama)
1. Borrow `borrow_per_step` USDC sur AAVE
2. Swap USDC → WBTC via DeFiLlama
3. Le WBTC arrive directement en aEthWBTC (collateral)
4. Vérifier le Health Factor

### À la hausse
Aucune action. Garder tous les shorts ouverts pour maximiser le carry.

---

## Gestion par Health Factor

**Toutes les décisions** dépendent exclusivement du Health Factor AAVE. Le prix spot n'est qu'un déclencheur d'accumulation, jamais une limite.

```
HF ≥ 1.50    ✅ Accumulation normale (aucune restriction)
HF 1.40–1.50 👁️ Monitor renforcé (emprunts toujours autorisés)
HF < 1.40    🛑 STOP total nouveaux emprunts
HF ≤ 1.30    ⚠️ Vendre 50 % puts → rembourser 25 % dette
HF ≤ 1.25    🔶 Vendre puts restants → rembourser 40 % dette
HF < 1.15    🚨 Vendre tout → rembourser max (ultra-défensif)
```

### Pourquoi HF et pas le prix ?

Le prix seul ne dit rien sur le risque réel. Avec le même prix à -30 %, le HF peut être à 1.8 (si peu de dette) ou à 1.3 (si beaucoup emprunté). Le HF capture la réalité : collateral × liquidation_threshold / dette.

Le buffer 18 % USDC agit comme amortisseur : il ne fluctue pas avec le prix BTC, ce qui maintient le HF plus stable que dans une position 100 % WBTC.

---

## Protection Puts OTM

Automatisation basée sur le **WBTC accumulé** et le **HF courant**.

### Variable de tracking

```
WBTC_extra_percent = (WBTC_total_AAVE − WBTC_start) / WBTC_start × 100
```

### Déclenchement achat / roll

| Condition | Couverture | Strike | Expiry |
|-----------|------------|--------|--------|
| Extra ≥ 6 % **ET** HF ≥ 1.68 | 60 % du WBTC extra | −26 % à −28 % OTM | 45–60 j |
| Extra ≥ 14 % **ET** HF ≥ 1.56 | 85 % du WBTC extra | −23 % à −24 % OTM | 35–50 j |
| Extra ≥ 24 % (tout HF > 1.35) | 100 % du WBTC extra | −21 % OTM | 30–45 j |

### Ajustements dynamiques par HF

| HF | Ajustement |
|----|------------|
| 1.55–1.70 | +15 points couverture, strike resserré de 2 % |
| 1.40–1.55 | Direct 100 % couverture + strike −20 % |
| < 1.40 | Arrêt achat → mode monétisation uniquement |

### Contraintes pratiques
- **Taille minimale** : WBTC extra ≥ 0.20 BTC (~$20-25k) pour éviter les micro-TX L1
- **Roll** : automatique tous les 30–35 jours si condition toujours remplie
- **Financement** : 100 % sur le cash carry Deribit (jamais le buffer 18 %)

---

## Équilibrages

| Type | Méthode |
|------|---------|
| **Intra-AAVE** | DeFiLlama uniquement (emprunt USDC → aEthWBTC). Aucun Collateral Swap pendant le cycle. |
| **AAVE ↔ Deribit** | Via HF (vente puts / profits shorts → repay dette). Transfert cash carry tous 7–14 jours. |
| **Reset 79/18/3** | Au nouvel ATH uniquement. Ajustement manuel du collateral. |

---

## Infrastructure technique

### Stack

```
Node.js + Express
├── server.js          Dashboard API (AAVE on-chain + Deribit REST)
├── notifier.js        Bot Telegram de notifications (@BTSave_bot)
├── public/
│   ├── index.html     Dashboard production (mobile-first)
│   ├── simu.html      Interface simulateur
│   └── simu.js        Moteur de simulation HF-based
└── grid-ws/
    └── grid-ws.js     WebSocket Deribit (fill detection)
```

### Données en temps réel

- **AAVE** : lecture on-chain via Etherscan (Pool contract, UserAccountData)
- **Deribit** : REST API (positions, ordres, options) + WebSocket (fills)
- **Prix BTC** : Deribit TradingView chart data (candles 15min)
- **Gas ETH** : estimation coût swap L1 en temps réel

---

## Dashboard de production

Interface mobile-first avec rafraîchissement auto 60s.

### Sections
- **Header** : prix BTC, step actuel, répartition live, ATH, pas
- **Paramètres du cycle** : buffer, cible Deribit, emprunt/palier, short/palier
- **Solde ETH** : balance + coût gas swap estimé
- **Chart** : candles 24h avec annotations (steps, prix courant)
- **AAVE V3** : HF, collateral détaillé, dette, LTV, net, prix liquidation
- **BTC Net @ ATH** : projection du gain net au prochain reset
- **Grid Gains** : P&L cumulé des fills grid
- **Deribit** : equity, ordres ouverts, positions futures, positions options (avec boutons CLOSE admin)
- **Prochaines actions** : recommandations HF-based contextuelles
- **Règles de gestion** : zones HF avec zone active surlignée

### Accès
- **Admin** : contrôle complet + fermeture de positions
- **Readonly** : monitoring sans actions de trading

---

## Simulateur

Moteur de simulation complet avec calcul HF réel (formule AAVE V3).

### Fonctionnalités
- Entrée du prix spot → calcul automatique du step, HF, zone
- Simulation step-by-step de la descente avec accumulation
- Tracking WBTC extra, dette, HF à chaque palier
- Application automatique des règles HF (stop emprunt, vente puts, repay)
- Visualisation P&L au reset (BTC net gagné par cycle)
- Stress test : scénarios -50 %, -70 %, -90 %

---

## Monitoring & Notifications

### Bot Telegram (@BTSave_bot)

Notifications image + caption à chaque franchissement de palier :
- Direction (↘️ baisse / ↗️ hausse)
- Numéro de step
- Prix
- Zone de gestion
- Actions automatiques et manuelles à réaliser

### WebSocket Monitor (grid-ws)

Service `deribit-grid-ws` (systemd) :
- Connexion WebSocket permanente à Deribit
- Détection instantanée des fills (sell stops)
- Notification Telegram avec rappel des actions manuelles
- Tracking des fills du cycle

### Sanity Check (cron 12h)

Vérification automatique toutes les 12h :
- Status du service WebSocket
- Prix BTC actuel
- Cohérence des ordres sell stops
- Position perp + options
- Mise à jour du fichier d'état

---

## Sécurité

### Risque de liquidation : 0 %

Quatre couches de protection :

1. **Buffer 18 % USDC** : ne fluctue pas avec le prix BTC, stabilise le HF
2. **Règles HF strictes** : stop emprunt à HF 1.40, monétisation puts dès HF 1.30
3. **Puts OTM automatiques** : protection du WBTC accumulé
4. **Exécution < 1h** : L1 Ethereum, pas de bridge, pas de L2

Même sans puts et en ignorant toutes les règles, le HF reste > 1.75 en cas de crash total grâce au buffer USDC.

### Authentification
- Session Express avec login/password
- Rôles admin / readonly
- Pas d'API keys exposées côté client

---

## Évolutivité

La stratégie est **100 % réutilisable à vie**. Chaque cycle est indépendant et entièrement déterministe. Les seules entrées sont : le prix spot BTC et le HF AAVE.

**Version finale verrouillée le 18 février 2026.**

---

*BTSAVE — Parce que chaque dip est une opportunité, pas un risque.*
