# 🧪 Guide de Test — Turbo Paper Boat Vault (Sepolia)

## Prérequis

- Wallet avec du Sepolia ETH (deployer ou Safe)
- Blockscout Sepolia : https://eth-sepolia.blockscout.com

---

## Test 1 : Premier Deposit (100 USDC)

### Étape 1 — Mint des USDC mock

Le deployer a déjà 100k USDC. Si tu veux tester avec un autre wallet :

1. Va sur le contrat USDC mock : https://eth-sepolia.blockscout.com/address/0x348e428E72893f6c756Cc3DDC04113b805b3b5D5?tab=write_proxy
2. Connecte le wallet deployer
3. Appelle `mint(address to, uint256 amount)` :
   - `to` : l'adresse qui va déposer
   - `amount` : `100000000` (= 100 USDC, 6 decimals)

### Étape 2 — Approve le Vault

1. Reste sur le contrat USDC : https://eth-sepolia.blockscout.com/address/0x348e428E72893f6c756Cc3DDC04113b805b3b5D5?tab=write_proxy
2. Appelle `approve(address spender, uint256 value)` :
   - `spender` : `0x1B504E187D163eB3fA08A67A9052f80bcad7705a` (Vault)
   - `value` : `100000000` (100 USDC)

### Étape 3 — Deposit

1. Va sur le Vault : https://eth-sepolia.blockscout.com/address/0x1B504E187D163eB3fA08A67A9052f80bcad7705a?tab=write_proxy
2. Appelle `deposit(uint256 assets, address receiver)` :
   - `assets` : `100000000` (100 USDC)
   - `receiver` : ton adresse wallet

### Étape 4 — Vérifier

1. Onglet "Read Proxy" du Vault
2. Appelle `balanceOf(address)` avec ton adresse → tu devrais voir des TPB shares
3. Appelle `totalAssets()` → devrait inclure tes 100 USDC + les aTokens simulés

---

## Test 2 : Cycle Reset via Safe Multisig

> ⚠️ Le resetCycle se fait via la Strategy, pas le Vault directement.

### Option A — Depuis le deployer (plus simple pour tester)

1. Va sur la Strategy : https://eth-sepolia.blockscout.com/address/0x411dD419AbE0DD9d0608a73E9c5fC665cD6E657e?tab=write_proxy
2. Connecte le wallet deployer (`0x490C...`)
3. Appelle `resetCycle()` (pas de paramètres)
4. Vérifie :
   - Strategy Read : `currentCycle()` → devrait retourner `(1, true, timestamp)`
   - Vault Read : `lastHarvest()` → timestamp mis à jour

### Option B — Depuis le Safe Multisig

1. Va sur https://app.safe.global
2. Connecte le Safe `0x17046a5927beBF2a015f6185A224862f677dDfa4`
3. New Transaction → Transaction Builder
4. Adresse : `0x411dD419AbE0DD9d0608a73E9c5fC665cD6E657e`
5. ABI : colle l'ABI de StrategyHybridAccumulator (ou entre manuellement)
6. Fonction : `resetCycle()`
7. Signe avec 2/3 signataires → Execute

### Option C — Via Oracle (simule un nouvel ATH)

C'est le flow réel : l'oracle détecte un ATH et appelle automatiquement resetCycle.

1. Va sur l'Oracle : https://eth-sepolia.blockscout.com/address/0xFE08a1Ca37DE2d431FdF53083E3D3a72Eb5E0467?tab=write_proxy
2. Appelle `updateATH()`
3. ⚠️ Ça ne marchera que si le prix BTC Chainlink Sepolia > $90,000 (l'ATH initial). Si le feed Sepolia donne un prix inférieur, ça revert avec `PriceNotHigherThanATH()`.
4. Alternative : baisse l'ATH d'abord via un nouveau déploiement, ou teste via Option A/B.

---

## Test 3 : Mint NFT Manuel

> Le VRF Chainlink nécessite un subscription ID actif. Sans ça, on utilise `triggerNFTMintManual`.

### Étape 1 — Trigger le mint

1. Va sur la Strategy : https://eth-sepolia.blockscout.com/address/0x411dD419AbE0DD9d0608a73E9c5fC665cD6E657e?tab=write_proxy
2. Connecte le wallet deployer
3. Appelle `triggerNFTMintManual(address user, uint256 avgBalance)` :
   - `user` : l'adresse du holder à récompenser
   - `avgBalance` : `100000000` (100 USDC — doit être ≥ 100e6)

> ⚠️ Sans VRF subscription active, l'appel au VRF Coordinator va revert. Deux options :
>
> **Option 1 : Créer un VRF subscription**
> 1. Va sur https://vrf.chain.link
> 2. Create Subscription sur Sepolia
> 3. Fund avec du LINK
> 4. Add consumer : `0xedF6Cd025012CbD926e673623F8418551332B83F` (NFT proxy)
> 5. Note le subscription ID
> 6. Mets à jour le contrat NFT via `setSubscriptionId(uint64)` si disponible, sinon il faudra redeploy avec le bon ID
>
> **Option 2 : Test sans VRF (recommandé pour MVP)**
> On peut modifier le contrat pour un mode test sans VRF. Dis-moi si tu veux que je déploie une version avec un fallback `block.prevrandao` pour les tests.

---

## Test 4 : Redeem (retrait)

> Les retraits ne fonctionnent que si la fenêtre de redemption est ouverte.

### Vérifier la fenêtre

1. Oracle Read : `isRedemptionWindowOpen()` → `true` ou `false`
2. La fenêtre est ouverte quand BTC price ∈ [ATH × 95%, ATH]
3. ATH initial = $90,000, donc fenêtre = [$85,500 — $90,000]
4. Si le feed Chainlink Sepolia donne un prix dans cette bande → fenêtre ouverte

### Redeem

1. Vault Write : `redeem(uint256 shares, address receiver, address owner)` :
   - `shares` : montant de TPB shares à burn (voir `balanceOf`)
   - `receiver` : adresse qui reçoit les USDC
   - `owner` : ton adresse
2. Si fenêtre fermée → revert `RedemptionWindowClosed()`

---

## Test 5 : Harvest (collecte des fees)

1. Va sur le Vault : Write Proxy
2. Appelle `harvest()` (deployer ou OPERATOR)
3. Vérifie dans Read :
   - `lastHarvest()` → timestamp mis à jour
   - `balanceOf(treasury)` → des shares de management fee devraient apparaître

---

## Résumé des commandes Cast (CLI)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
RPC="https://0xrpc.io/sep"
PK="<deployer_private_key>"
VAULT="0x1B504E187D163eB3fA08A67A9052f80bcad7705a"
USDC="0x348e428E72893f6c756Cc3DDC04113b805b3b5D5"
STRATEGY="0x411dD419AbE0DD9d0608a73E9c5fC665cD6E657e"
ORACLE="0xFE08a1Ca37DE2d431FdF53083E3D3a72Eb5E0467"

# Approve + Deposit 100 USDC
cast send $USDC "approve(address,uint256)" $VAULT 100000000 --rpc-url $RPC --private-key $PK
cast send $VAULT "deposit(uint256,address)" 100000000 <your_address> --rpc-url $RPC --private-key $PK

# Check shares
cast call $VAULT "balanceOf(address)" <your_address> --rpc-url $RPC

# Check total assets
cast call $VAULT "totalAssets()" --rpc-url $RPC

# Reset cycle
cast send $STRATEGY "resetCycle()" --rpc-url $RPC --private-key $PK

# Harvest fees
cast send $VAULT "harvest()" --rpc-url $RPC --private-key $PK

# Check redemption window
cast call $ORACLE "isRedemptionWindowOpen()" --rpc-url $RPC
```
