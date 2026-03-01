# WHITEPAPER BTSAVE – TOKEN TPB

> Version 1.0 – 28 février 2026
> Projet open-source : https://github.com/adeloing/btsave

**Conforme aux exigences de forme du Règlement MiCA (Markets in Crypto-Assets – Règlement (UE) 2023/1114)**
Article 6 et suivants – Whitepaper pour offre au public d'actifs cryptographiques (catégorie Utility/Participation Token)

---

## ⚠️ AVERTISSEMENT IMPORTANT

Ce document constitue une présentation informative et éducative du protocole BTSAVE et du token TPB. Il n'est pas une offre de titres, une invitation à investir, ni un conseil financier, juridique ou fiscal. Le projet est entièrement open-source et décentralisé. Aucun émetteur centralisé ne garantit la valeur, la performance ou la liquidité du token TPB. **Vous pouvez perdre la totalité de votre apport.** Lisez attentivement la section « Facteurs de Risque » avant toute interaction.

---

## 1. Résumé (Summary – MiCA Art. 6(1))

BTSAVE est un vault DeFi sur Ethereum L1 conçu pour l'accumulation agressive et sans liquidation de Bitcoin (WBTC). Le token **TPB (Turbo Paper Boat)** est un token de participation utilitaire ERC-4626 représentant une quote-part proportionnelle des actifs du vault (WBTC + valeur de la stratégie).

- **Dépôt exclusif** : uniquement WBTC
- **Minting** : NAV-based (anti-dilution des early users)
- **Transferable** : 100 % libre (comme les NFTs du projet)
- **Redeem** : à tout moment contre WBTC (`previewRedeem` visible)
- **Stratégie** : 79 % collateral aEthWBTC + 18 % buffer USDC + 3 % Deribit, shorts PERP contango + puts OTM dynamiques
- **Cycle** : reset uniquement sur nouvel ATH BTC ratcheté (gain net permanent)
- **Objectif** : transformer chaque dip BTC en accumulation nette de BTC sans risque de liquidation

Le protocole est **zéro-liquidation par construction** (gestion stricte du Health Factor AAVE + protections automatisées).

Version finale de la stratégie verrouillée le 18 février 2026. Contrats mis à jour le 28 février 2026 avec VaultTPB v2 (NAV ERC-4626).

**Aucune levée de fonds, aucun ICO, aucun token de gouvernance.** TPB est un receipt token utilitaire open-source.

---

## 2. Description du Projet et de l'Émetteur (MiCA Art. 6(2))

**Projet** : BTSAVE est un protocole DeFi open-source développé par la communauté Bitcoin-maximaliste sous le pseudonyme « adeloing ».

**Statut** : Projet communautaire, non enregistré en tant que société, sans entité juridique centralisée. Le code source est entièrement auditable sur GitHub (43 commits au 28/02/2026).

**Objectif du projet** : Offrir aux holders de Bitcoin un outil on-chain permettant d'accumuler plus de BTC lors des baisses de prix tout en protégeant le capital contre les liquidations, grâce à une stratégie hybride lending + derivatives.

**Raisons de l'offre** : Fournir un produit DeFi simple, transparent et 100 % BTC-centric (dépôt/réception en WBTC uniquement) qui respecte la philosophie « not your keys, not your coins » tout en maximisant l'exposition long-term au Bitcoin.

**Utilisation des proceeds** : Il n'y a aucune levée de fonds. Les frais éventuels du vault (0,5-1 % à définir) servent exclusivement à couvrir les coûts opérationnels (gas, keeper, monitoring Telegram). Aucune rémunération n'est versée à une équipe ou fondation.

---

## 3. Description du Token TPB (MiCA Art. 6(3) – Art. 7)

| Propriété | Détail |
|-----------|--------|
| **Nom** | TPB (Turbo Paper Boat) |
| **Symbole** | TPB |
| **Standard** | ERC-20 + ERC-4626 (Vault Shares) |
| **Décimales** | 8 (aligné sur les satoshis) ou 18 (standard – à confirmer en mainnet) |
| **Supply** | Dynamique et illimitée (mint au dépôt + rewards performance) |

**Minting** :

- **Premier dépôt** : 1 WBTC = 1e8 TPB (1:1)
- **Dépôts suivants** : `shares = (wbtcAmount × totalSupply) / totalAssets` (NAV-based → anti-dilution totale)

**Redeem** : Burn TPB → WBTC équivalent (swap automatique via DeFiLlama si nécessaire)

**Transferable** : 100 % libre dès le mint (pas de lock, pas de soulbound)

**Events** : `Deposited`, `Redeemed`, `CycleReset`

TPB n'est pas un security, un ART (Asset-Referenced Token), un EMT ou un token de paiement. C'est un token utilitaire de participation à un vault DeFi open-source.

---

## 4. Stratégie Technique et Mécanismes (Détails Opérationnels)

**Allocation initiale post-reset** : 79 % aEthWBTC + 18 % buffer aEthUSDC + 3 % marge Deribit.

**Mécanisme de cycle** (verrouillé 18/02/2026) :

- Cycle commence et se termine uniquement sur nouvel ATH BTC ratcheté.
- À chaque palier −5 % depuis l'ATH : borrow USDC → swap DeFiLlama → aEthWBTC + short BTC-PERP Deribit.
- Protection : puts OTM dynamiques financés par le carry contango (déclenchements à +6 %, +14 %, +24 % WBTC extra).

**Reset ATH** :

1. Clôture tous les shorts → profits = bonus pur
2. Vente du minimum WBTC (P2) pour rembourser 100 % dette USDC
3. Conservation de tout le reste = gain net permanent
4. Rebalance 79/18/3 → nouveau cycle

**Gestion du risque** : tout est piloté par le Health Factor AAVE (zones HF 1.50 / 1.40 / 1.30 / 1.15) et non par le prix seul. Exécution manuelle assistée par bots + Telegram alerts (<1h sur L1).

**Keeper** : met à jour `safeWBTC` à chaque gain (performance + bonus Deribit).

---

## 5. Fonctionnement Technique des Smart Contracts

- **VaultTPB v2 (ERC-4626)** : `depositWBTC`, `redeem`, `previewRedeem`, `notifyCycleEnd`.
- **TPB.sol** : mint/burn restreints au Vault, transferts libres.
- **Intégrations** : AAVE V3 Pool, DeFiLlama Aggregator, Deribit API (off-chain keeper).
- **Tests** : 36/36 passés sur Sepolia, dont test anti-dilution Alice (early) vs Bob (late).
- **Audit** : audit professionnel en cours – sera publié avant mainnet.

Code source complet et auditable : https://github.com/adeloing/btsave/tree/main/contracts

---

## 6. Facteurs de Risque (MiCA Art. 6(4) – Exhaustif)

**Risques de perte totale ou partielle** :

- Bug smart contract ou hack de protocole (AAVE, Deribit, oracle)
- Contrepartie Deribit (exchange risk)
- Événement extrême Bitcoin (>50 % chute en peu de temps)
- Risque d'exécution (retard keeper, gas spike, slippage)
- Risque de liquidité du vault en cas de rush redeem massif
- Risque réglementaire : évolution MiCA, interdictions locales, taxes
- Risque technique Ethereum (reorg, congestion)
- Risque opérationnel (erreur humaine du keeper)
- **Aucun capital garanti – aucune assurance**

**Risque de dilution** : nul grâce au minting NAV-based.

**Risque de performance** : aucune garantie de rendement ; les performances passées (simulateur) ne préjugent pas des résultats futurs.

**Risques spécifiques au token** :

- Volatilité du prix TPB sur marchés secondaires
- Perte d'accès wallet
- Rug-pull inexistant (open-source, pas de clé admin centralisée après déploiement)

---

## 7. Aspects Légaux et Réglementaires (MiCA Compliance)

**Classification** : TPB est un crypto-asset utilitaire au sens MiCA (non ART, non EMT, non security). Le projet ne constitue pas une offre au public au sens strict nécessitant approbation CASP ou autorité nationale (offre décentralisée open-source).

**Responsabilité** : Le projet décline toute responsabilité pour pertes directes, indirectes ou consécutives. L'utilisateur est seul responsable de sa due diligence et de sa conformité fiscale/juridique dans sa juridiction.

**Taxes** : L'utilisateur doit déclarer tout gain, dépôt ou redemption conformément à la législation locale.

**Âge** : Réservé aux personnes majeures (≥18 ans) et éligibles dans leur pays.

**Modification** : Le projet se réserve le droit d'évoluer la stratégie ou le code tout en respectant l'esprit zéro-liquidation et accumulation BTC.

**Acceptation** : L'utilisation du protocole ou la détention de TPB vaut acceptation pleine et entière du présent whitepaper et des risques.

---

## 8. Gouvernance et Équipe

- **Gouvernance** : 100 % on-chain + communauté GitHub/Discord. Pas de token de gouvernance.
- **Équipe** : Développeur principal pseudonyme « adeloing » + contributeurs open-source. Aucun KYC public.
- **Transparence** : Tout le code, la stratégie et les tests sont publics depuis le lancement.

---

## 9. Comment Participer

1. Connecter un wallet compatible Ethereum (mainnet).
2. Déposer uniquement du WBTC.
3. Recevoir TPB instantanément.
4. Suivre via dashboard + Telegram bot @BTSave\_bot.

---

## 10. Informations Environnementales (MiCA Art. 6(8))

**Consensus** : Ethereum L1 utilise le Proof of Stake (PoS) depuis « The Merge » (septembre 2022), réduisant la consommation énergétique de ~99,95 % par rapport au Proof of Work.

**Impact estimé** : Le vault génère en moyenne 5-15 transactions Ethereum L1 par cycle (emprunts, swaps, remboursements). L'empreinte carbone est négligeable comparée aux opérations de mining Bitcoin.

**Aucune infrastructure de mining** n'est opérée par le projet.

---

## 11. Annexes

### A. Liens et Ressources

| Ressource | URL |
|-----------|-----|
| Code source | https://github.com/adeloing/btsave |
| Documentation utilisateur | https://github.com/adeloing/btsave/blob/main/docs/USER-GUIDE.md |
| Dashboard (live) | https://ratpoison2.duckdns.org/hedge/ |
| Monitoring Grafana | https://ratpoison2.duckdns.org/grafana/ |
| Telegram bot | @BTSave\_bot |
| Testnet (Sepolia) | Contrats déployés et testés (66/66 tests) |

### B. Glossaire

| Terme | Définition |
|-------|-----------|
| **ATH** | All-Time High — prix record du Bitcoin |
| **NAV** | Net Asset Value — valeur nette des actifs du vault par token |
| **HF** | Health Factor — ratio de solvabilité AAVE (> 1 = solvable) |
| **TPB** | Turbo Paper Boat — token de participation du vault BTSAVE |
| **WBTC** | Wrapped Bitcoin — BTC tokenisé sur Ethereum |
| **Contango** | Situation où le prix futur > prix spot (carry positif sur les shorts) |
| **Put OTM** | Option de vente hors de la monnaie (protection contre la baisse) |
| **LSM** | LimitedSignerModule — module Gnosis Safe de sécurité on-chain |
| **Keeper** | Bot automatisé qui exécute les opérations du vault |

### C. Historique des versions

| Version | Date | Changements |
|---------|------|-------------|
| 1.0 | 28/02/2026 | Version initiale du whitepaper MiCA |

---

*Ce whitepaper est un document vivant. La dernière version est toujours disponible sur le dépôt GitHub du projet.*

*BTSAVE – Février 2026*
