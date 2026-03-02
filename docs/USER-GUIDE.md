# ✅ Documentation Utilisateur Officielle – Turbo Paper Boat (TPB)

> Version 2.0 – 2 mars 2026
> Projet open-source : https://github.com/adeloing/btsave

---

## 1. Qu'est-ce que Turbo Paper Boat ?

**Turbo Paper Boat (TPB)** est le produit phare de **BTSAVE** — un vault d'accumulation BTC agressive et zéro-liquidation, entièrement on-chain sur **Arbitrum**. Il transforme chaque baisse de prix du Bitcoin en gain net de BTC grâce à :

- **AAVE V3 Arbitrum** (collateral WBTC + buffer USDC)
- **GMX V2** (shorts BTC split: profit-taking + insurance)
- **Aevo** (puts OTM: protection catastrophe + drawdown modéré)
- **Camelot DEX** (swaps USDC ↔ WBTC pour rebalancing)

**Cycle complet** : le vault ne reset que lors d'un nouveau ATH Bitcoin ratcheté. À chaque reset, il rembourse 100 % de la dette USDC. Tout le WBTC restant est du gain net permanent.

---

## 2. Le Token TPB (Turbo Paper Boat)

TPB est le token de participation du vault BTSAVE (standard ERC-4626). Il représente votre part proportionnelle des actifs du vault.

**Caractéristiques clés** :

- **Totalement transférable** — tradable sur DEX dès le mint
- **NAV-based** — protège automatiquement les early users contre toute dilution
- **Entry fee** : 2% base (5% near ATH), réduit par NFTBonus (jusqu'à ~44% du fee de base)
- **Exit fee progressif** : 2% (<7j) → 1% (<30j) → 0.5% (<90j) → 0% (≥90j), +1% si drawdown >10%
- **Redeemable** à tout moment (exit fee applicable)

---

## 3. Comment fonctionne le dépôt et le retrait ?

### Dépôt (uniquement WBTC)

1. Entry fee déduit automatiquement (envoyé au treasury)
2. WBTC net envoyé à la stratégie (supply AAVE V3)
3. TPB mintés selon la NAV

```
shares = previewDeposit(wbtcAmount)  // fee déjà déduit
```

### Retrait

1. TPB brûlés
2. WBTC retiré de la stratégie (withdraw AAVE V3)
3. Exit fee appliqué selon durée de holding + conditions marché
4. WBTC net envoyé au receiver

```
assets = previewWithdraw(wbtcAmount)  // ou previewRedeem(shares)
```

### Exit Fees Détaillés

| Durée holding | Fee de base | + Bonus drawdown* |
|---------------|------------|-------------------|
| < 7 jours | 2.0% | +1.0% |
| 7-29 jours | 1.0% | +1.0% |
| 30-89 jours | 0.5% | +1.0% |
| ≥ 90 jours | **0%** | — |

*Le bonus drawdown s'applique quand BTC < 90% de l'ATH (drawdown > 10%)

---

## 4. Stratégie technique

- **Allocation** : 82% WBTC (AAVE collateral) + 15% USDC buffer + 3% hedging (2% GMX + 1% Aevo)
- **GMX V2 shorts** : split en profit-taking (close par paliers +12/25/40%) et insurance (close sur recovery)
- **Aevo puts** : P1 à 60% ATH + P2 à 85% ATH, reopen si BTC <-7% ATH ou HF < 2.6
- **Cash flow** : priorité debt repay si HF bas, sinon accumulate WBTC via Camelot
- **Rebalancing** : automatique à ±3% de drift ou tous les 14 jours
- **Reset ATH** : clôture tout → repay dette → IDLE → nouveau cycle

---

## 5. Risques importants

⚠️ **Perte totale possible** : bug smart contract, hack de protocole (AAVE, GMX, Aevo), événement extrême.

⚠️ **Volatilité extrême** : le Bitcoin peut chuter >50% rapidement.

⚠️ **Risques DeFi** : smart contract risk, slippage, oracle manipulation.

⚠️ **Risques réglementaires** : évolution MiCA, taxes, interdictions locales.

⚠️ **Risque de liquidité** : si la stratégie a des positions ouvertes, le WBTC disponible peut être limité.

⚠️ **Pas de garantie** : aucun rendement minimum, aucun capital garanti.

---

## 6. Disclaimers Légaux

**CECI N'EST PAS UN CONSEIL FINANCIER, D'INVESTISSEMENT OU FISCAL.**

BTSAVE et le token TPB sont fournis à titre informatif et éducatif uniquement.

**Aucune garantie de performance.** Vous pouvez perdre 100% de votre apport.

**Responsabilité limitée.** Vous êtes seul responsable de vos décisions et pertes.

**Pas une offre de titres.** TPB est un token utilitaire ERC-4626 open-source.

**Taxes.** Vous êtes seul responsable de déclarer et payer les taxes applicables.

**Âge et éligibilité.** ≥18 ans, légalement autorisé dans votre juridiction.

> **En utilisant BTSAVE ou en détenant du TPB, vous acceptez pleinement ces termes.**

---

## 7. Comment commencer ?

1. Connectez votre wallet sur Arbitrum
2. Approuvez WBTC pour le vault
3. Déposez du WBTC → recevez TPB
4. Suivez votre position sur le dashboard
5. Retirez quand vous voulez (exit fee selon durée)

**Ressources** :

- Repo : [https://github.com/adeloing/btsave](https://github.com/adeloing/btsave)
- Dashboard : [turbopaperboat.com/dashboard/](https://turbopaperboat.com/dashboard/)
- Landing : [turbopaperboat.com](https://turbopaperboat.com)

---

*L'équipe BTSAVE – Mars 2026*
