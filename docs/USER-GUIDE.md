# ✅ Documentation Utilisateur Officielle – Turbo Paper Boat (TPB)

> Version 1.0 – 28 février 2026
> Projet open-source : https://github.com/adeloing/btsave

---

## 1. Qu'est-ce que Turbo Paper Boat ?

**Turbo Paper Boat (TPB)** est le produit phare de **BTSAVE** — un token vault d'accumulation BTC agressive et zéro-liquidation sur Ethereum L1. Il transforme chaque baisse de prix du Bitcoin en gain net de BTC tout en protégeant strictement le capital grâce à :

- **AAVE V3** (collateral WBTC + buffer USDC)
- **Short BTC-PERP sur Deribit** (carry contango)
- **Puts OTM dynamiques** (protection financée par le carry)

**Cycle complet** : le vault ne reset que lors d'un nouveau ATH Bitcoin ratcheté. À chaque reset, il rembourse 100 % de la dette USDC en vendant le minimum strict de WBTC accumulé pendant le cycle. Tout le reste est conservé comme gain net permanent.

**Objectif** : maximiser l'exposition BTC long-term tout en minimisant les risques de liquidation.

**BTSAVE** est l'entreprise qui conçoit et opère la stratégie. **Turbo Paper Boat (TPB)** est le produit — le token que vous détenez.

---

## 2. Le Token TPB (Turbo Paper Boat)

TPB est le token de receipt et de participation du vault de BTSAVE (standard ERC-4626). Il représente votre part proportionnelle des actifs du vault (WBTC + valeur de la stratégie).

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

⚠️ **Risques réglementaires** : les produits dérivés, le lending et les vaults DeFi peuvent être soumis à des réglementations changeantes selon votre juridiction (KYC, taxes, interdictions locales).

⚠️ **Risque de liquidité** : en cas de rush de redemption massif, le vault peut temporairement manquer de WBTC liquide (même si un buffer est maintenu).

⚠️ **Pas de garantie** : aucun rendement minimum, aucun capital garanti.

---

## 6. Disclaimers Légaux & Mentions Légales Obligatoires

**CECI N'EST PAS UN CONSEIL FINANCIER, D'INVESTISSEMENT OU FISCAL.**

BTSAVE et le token Turbo Paper Boat (TPB) sont fournis à titre informatif et éducatif uniquement. Aucune personne ou entité liée au projet (développeurs, contributeurs, opérateurs du keeper, communauté) ne vous donne de conseil d'investissement.

**Aucune garantie de performance.** Les performances passées (simulateur ou cycles précédents) ne préjugent en rien des résultats futurs. Vous pouvez perdre 100 % de votre apport.

**Responsabilité limitée.** En utilisant le vault, vous acceptez que :

- Vous êtes seul responsable de vos décisions et de vos pertes.
- Le projet décline toute responsabilité pour tout dommage direct, indirect, incident ou consécutif.
- Vous avez effectué votre propre due diligence technique, financière et juridique.
- Vous comprenez les risques inhérents à la blockchain, à Ethereum, à AAVE, à Deribit et aux stratégies de lending/hedging.

**Pas une offre de titres.** TPB n'est pas une security, une action, une obligation ni un produit d'investissement réglementé. Il s'agit d'un token utilitaire représentant une part d'un vault DeFi open-source.

**Taxes.** Vous êtes seul responsable de déclarer et payer les taxes applicables dans votre juridiction sur les gains, les dépôts et les redemptions.

**Âge et éligibilité.** Vous devez avoir au moins 18 ans et être légalement autorisé à utiliser ces protocoles dans votre pays de résidence.

**Audit & Sécurité.** Les contrats sont en cours de tests intensifs sur Sepolia (36/36 tests passés dont anti-dilution). Un audit professionnel sera publié avant mainnet. Utilisez à vos risques et périls.

**Modification.** Le projet se réserve le droit de faire évoluer la stratégie, les paramètres ou le code sans préavis, dans la mesure où cela reste conforme à l'esprit zéro-liquidation et accumulation BTC.

> **En utilisant BTSAVE ou en détenant du TPB, vous acceptez pleinement ces termes. Si vous n'êtes pas d'accord, n'utilisez pas le protocole.**

---

## 7. Comment commencer ?

1. Connectez votre wallet (MetaMask, etc.) sur le site officiel (à venir).
2. Déposez uniquement du WBTC (Ethereum mainnet).
3. Recevez vos TPB instantanément.
4. Suivez votre position sur le dashboard + Telegram bot @BTSave\_bot.
5. Redeem quand vous voulez via l'interface.

**Ressources** :

- Repo complet : [https://github.com/adeloing/btsave](https://github.com/adeloing/btsave)
- Dashboard & simulateur (live)
- Telegram notifier
- Tests & code source auditable

**Support** : uniquement via Discord/GitHub issues (pas de support privé).

---

Vous êtes maintenant pleinement informé. Turbo Paper Boat est un produit puissant pour les Bitcoiners convaincus, mais il reste un produit DeFi expérimental à haut risque. **Utilisez uniquement ce que vous pouvez vous permettre de perdre complètement.**

Bienvenue dans le vault. ⚡

*L'équipe BTSAVE – Février 2026*

*(Ce document est public et peut être mis à jour. Dernière version toujours sur le repo.)*
