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

**Fonctionnalités** :

- Représente une quote-part pro-rata des actifs du vault (`totalAssets = WBTC liquide + safeWBTC`)
- Mintable uniquement par dépôt de WBTC dans le vault (aucun pre-mine, aucune allocation team)
- Redeemable contre du WBTC à tout moment (au prorata de la NAV)
- Transferable librement (ERC-20 standard)
- Bonus de performance mintés automatiquement en fin de cycle (nouvel ATH) au prorata des holdings
- Multiplicateur NFT optionnel (collection ERC-1155, 4 tiers)

**Droits conférés** :

- Droit à une quote-part des actifs du vault (WBTC)
- Droit de redemption (burn TPB → recevoir WBTC)
- Droit de transfert libre
- Aucun droit de gouvernance
- Aucun droit de vote
- Aucun dividende (les gains sont reflétés dans la NAV du token)

**Mécanisme de prix** :

```
sharePrice = totalAssets / totalSupply
```

Le prix du TPB évolue avec la performance de la stratégie. En cas de gains, chaque TPB représente plus de WBTC. En cas de pertes, chaque TPB représente moins de WBTC.

Sur le marché secondaire (DEX), le TPB peut trader au-dessus ou en-dessous de sa NAV selon l'offre et la demande.

---

## 4. Technologie et Blockchain (MiCA Art. 6(4))

**Blockchain** : Ethereum L1 (mainnet)

**Protocoles utilisés** :

| Protocole | Rôle | Risque spécifique |
|-----------|------|-------------------|
| AAVE V3 | Lending/borrowing (collateral + buffer) | Smart contract risk, oracle risk |
| Deribit | Shorts PERP + Puts OTM (CeFi) | Risque de contrepartie, KYC |
| DeFiLlama / 1inch | Agrégateur de swaps | Slippage, MEV |
| Gnosis Safe | Multisig 2/2 pour exécution | Risque de clé privée |

**Smart Contracts** :

| Contrat | Description | Tests |
|---------|-------------|-------|
| `VaultTPB.sol` | Vault + ERC-20 TPB token | 36/36 ✅ |
| `LimitedSignerModule.sol` | Module Gnosis Safe (19 règles on-chain) | 30/30 ✅ |
| `NFTBonus.sol` | ERC-1155 NFT bonus system | Inclus dans VaultTPB tests |

**Sécurité on-chain (LimitedSignerModule v3)** :

- 19 règles de validation automatiques
- Consensus multi-bot (2/3 minimum)
- Kill switch (2/2 humains uniquement)
- Health Factor minimum : 1.55
- Plafond gas : 80 gwei (auto-reset)
- Volume daily caps (borrow + swap)
- Whitelisting targets + selectors
- Code hash pinning
- Proposal TTL 30 min (auto-expire)

**Audit** : Tests intensifs sur Sepolia (66/66 tests passés). Audit professionnel planifié avant déploiement mainnet.

---

## 5. Facteurs de Risque (MiCA Art. 6(5))

### Risques liés au token

- **Perte totale possible** : un bug de smart contract, un hack, un événement extrême ou une erreur humaine peut entraîner la perte partielle ou totale de votre apport.
- **Volatilité extrême** : le Bitcoin peut chuter de plus de 50 % rapidement. La valeur de vos TPB peut baisser fortement en cours de cycle.
- **Pas de garantie de capital** : aucun rendement minimum, aucun capital garanti, aucune assurance.
- **Risque de liquidité** : en cas de rush de redemption massif, le vault peut temporairement manquer de WBTC liquide.
- **Risque de marché secondaire** : le TPB peut trader significativement en-dessous de sa NAV sur les DEX.

### Risques liés à la technologie

- **Smart contract risk** : malgré 66 tests passés, aucun code n'est exempt de bugs. Un audit professionnel est planifié mais pas encore réalisé.
- **Risque oracle** : une manipulation du prix WBTC/USD sur l'oracle Chainlink pourrait affecter le Health Factor et déclencher des actions non désirées.
- **Risque de clé privée** : compromission des clés du multisig Gnosis Safe (2/2).
- **Risque de dépendance** : le protocole dépend d'AAVE V3, Deribit, Ethereum L1 et Chainlink. Une défaillance de l'un de ces protocoles impacte directement le vault.
- **Risque MEV** : les transactions de swap peuvent être frontrun ou sandwichées sur Ethereum L1.

### Risques liés au projet

- **Risque d'équipe** : projet pseudonyme, pas d'entité juridique, pas de recours légal en cas de perte.
- **Risque réglementaire** : les produits dérivés, le lending et les vaults DeFi peuvent être soumis à des réglementations changeantes (KYC, taxes, interdictions locales).
- **Risque opérationnel** : les keepers et bots doivent fonctionner 24/7. Une panne prolongée pourrait retarder des opérations critiques.
- **Risque de centralisation partielle** : Deribit est un exchange centralisé soumis au risque de contrepartie, gel de fonds, KYC rétroactif.

### Risques spécifiques à la stratégie

- **Risque de contango inversé** : si le funding rate BTC-PERP devient durablement négatif, les shorts deviennent coûteux au lieu de générer du carry.
- **Risque de corrélation** : en cas de crise systémique crypto, tous les actifs (WBTC, USDC, AAVE) peuvent être impactés simultanément.
- **Risque de depeg WBTC** : si WBTC perd sa parité avec BTC, le collateral AAVE perd de la valeur.
- **Risque de depeg USDC** : si USDC perd sa parité avec USD, le buffer et les emprunts sont affectés.

---

## 6. Informations sur l'Offre au Public (MiCA Art. 6(6))

**Type d'offre** : Aucune offre au public au sens traditionnel. Le protocole est open-source et permissionless. Tout utilisateur peut interagir avec les smart contracts directement.

**Prix d'émission** : Pas de prix fixe. Le prix du TPB est déterminé par la NAV du vault au moment du dépôt.

**Frais** :
- Frais de dépôt : 0 % (seul le gas Ethereum s'applique)
- Frais de redemption : 0 % (seul le gas s'applique)
- Frais de gestion : 0,5-1 % annualisé (à confirmer — couvre gas + keeper + monitoring)
- Frais de performance : à définir

**Allocation initiale** :
- Pre-mine : **0 TPB** (aucun)
- Allocation team : **0 TPB** (aucune)
- Allocation investisseurs : **0 TPB** (aucune)
- 100 % des TPB sont mintés uniquement par dépôt de WBTC par les utilisateurs

**Période d'offre** : Indéfinie (le vault accepte les dépôts en continu).

**Blockchain de déploiement** : Ethereum L1 (mainnet). Testnet Sepolia pour la phase de test actuelle.

---

## 7. Gouvernance et Droits (MiCA Art. 6(7))

**Gouvernance** : Aucune gouvernance on-chain. Les décisions stratégiques sont prises par les opérateurs du vault (multisig 2/2 Gnosis Safe).

**Droits des holders TPB** :
- ✅ Droit de redemption (burn → WBTC)
- ✅ Droit de transfert libre
- ✅ Droit de consulter la NAV en temps réel (`previewRedeem()`)
- ❌ Pas de droit de vote
- ❌ Pas de droit de gouvernance
- ❌ Pas de dividende

**Modification du protocole** : Le projet se réserve le droit de faire évoluer la stratégie, les paramètres ou le code, dans la mesure où cela reste conforme à l'esprit zéro-liquidation et accumulation BTC. Les modifications sont publiques (commits GitHub) et notifiées via Telegram.

---

## 8. Informations Environnementales (MiCA Art. 6(8))

**Consensus** : Ethereum L1 utilise le Proof of Stake (PoS) depuis « The Merge » (septembre 2022), réduisant la consommation énergétique de ~99,95 % par rapport au Proof of Work.

**Impact estimé** : Le vault génère en moyenne 5-15 transactions Ethereum L1 par cycle (emprunts, swaps, remboursements). L'empreinte carbone est négligeable comparée aux opérations de mining Bitcoin.

**Aucune infrastructure de mining** n'est opérée par le projet.

---

## 9. Annexes

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
