# ✅ Documentation Utilisateur Officielle – BTSAVE Vault & Token TPB

> Version 1.0 – 28 février 2026
> Projet open-source : https://github.com/adeloing/btsave

---

## 1. Qu'est-ce que BTSAVE ?

BTSAVE est un vault de stratégie d'accumulation BTC agressive et zéro-liquidation sur Ethereum L1. Il transforme chaque baisse de prix du Bitcoin en gain net de BTC tout en protégeant strictement le capital grâce à :

- **AAVE V3** (collateral WBTC + buffer USDC)
- **Short BTC-PERP sur Deribit** (carry contango)
- **Puts OTM dynamiques** (protection financée par le carry)

**Cycle complet** : le vault ne reset que lors d'un nouveau ATH Bitcoin ratcheté. À chaque reset, il rembourse 100 % de la dette USDC en vendant le minimum strict de WBTC accumulé pendant le cycle. Tout le reste est conservé comme gain net permanent.

**Objectif** : maximiser l'exposition BTC long-term tout en minimisant les risques de liquidation.

---

## 2. Le Token TPB (Turbo Paper Boat)

TPB est le token de receipt et de participation du vault (standard ERC-4626). Il représente votre part proportionnelle des actifs du vault (WBTC + valeur de la stratégie).

**Caractéristiques clés** :

- **Totalement transferable** — vous pouvez le vendre, le transférer ou le trader sur un DEX dès le mint (comme nos NFTs)
- **NAV-based** (Net Asset Value) — protège automatiquement les early users contre toute dilution
- **Satoshi-pegged en esprit** — 1 WBTC ≈ 100 000 000 TPB à l'entrée (mais ajusté par NAV ensuite)
- **Redeemable** à tout moment contre du WBTC (`previewRedeem()` visible)

---

## 3. Comment fonctionne le mint et le redeem ?

### Dépôt (uniquement WBTC accepté)

- **Premier dépôt** : 1:1 (1 WBTC = 1e8 TPB)
- **Dépôts suivants** : `shares = (wbtcAmount × totalSupplyTPB) / totalAssets`

→ Vous recevez moins de TPB si la valeur du vault a déjà augmenté grâce à la stratégie (**anti-dilution totale**)

```
totalAssets = WBTC liquide dans le vault + safeWBTC
```

`safeWBTC` = valeur réelle déployée dans la stratégie, mise à jour par le keeper à chaque gain.

### Fin de cycle (nouvel ATH)

1. La stratégie réalise ses profits (Deribit + accumulation)
2. Le keeper met à jour `safeWBTC`
3. Votre part de performance est automatiquement reflétée dans la NAV → **votre TPB vaut plus de WBTC**

### Redeem

- À tout moment via `redeem()` ou `previewRedeem()`
- Vous voyez exactement combien de WBTC vous récupérerez avant de confirmer
- Le vault brûle vos TPB et vous envoie le WBTC correspondant (swap automatique si besoin)

> ✅ **Test anti-dilution validé** : Alice (early) ne perd jamais de part quand Bob (late) dépose après une performance positive.

---

## 4. Stratégie technique (inchangée depuis le 18/02/2026)

- **Allocation initiale** : 79 % aEthWBTC + 18 % buffer aEthUSDC + 3 % marge Deribit
- **À chaque palier −5 % depuis l'ATH** : borrow USDC → swap → plus de aEthWBTC + short PERP
- **Protection HF stricte** (jamais de liquidation)
- **Puts OTM** auto-achetés sur l'excédent WBTC (financés par le carry)
- **Reset uniquement à nouveau ATH** : clôture shorts → profits bonus → remboursement dette minimal → rebalance 79/18/3

Tout est automatisé via keeper + bots, avec alertes Telegram et dashboard.

---

## 5. Risques importants (à lire attentivement)

⚠️ **Perte totale possible** : même avec une stratégie zéro-liquidation théorique, un bug de smart contract, un hack de protocole (AAVE, Deribit, oracle), un événement extrême ou une erreur humaine peut entraîner une perte partielle ou totale.

⚠️ **Volatilité extrême** : le Bitcoin peut chuter de plus de 50 % rapidement ; même si le vault est conçu pour accumuler, la valeur de vos TPB peut baisser fortement en cours de cycle.

⚠️ **Risques DeFi** : smart contract risk, risque de contrepartie Deribit, frais de gas, slippage sur swaps.
