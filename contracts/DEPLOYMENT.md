# Turbo Paper Boat Vault — Sepolia Deployment

**Network:** Ethereum Sepolia (chain 11155111)
**Deployed:** 2026-02-27
**Deployer:** `0x490CE9212cf474a5A73936a8d25b5Ef46751a58f`

## Contract Addresses

### Proxies (interact with these)

| Contract | Address |
|---|---|
| **Vault (TPB)** | `0x1B504E187D163eB3fA08A67A9052f80bcad7705a` |
| **OracleManager** | `0xFE08a1Ca37DE2d431FdF53083E3D3a72Eb5E0467` |
| **NFTCycleRewards** | `0xedF6Cd025012CbD926e673623F8418551332B83F` |
| **StrategyHybridAccumulator** | `0x411dD419AbE0DD9d0608a73E9c5fC665cD6E657e` |

### Implementations

| Contract | Address |
|---|---|
| TurboPaperBoatVault | `0xd836cb694944f879f3283d94528f41d1355b779d` |
| OracleManager | `0x09b6bebca45a191de387d1461a2ddd04dc8477ef` |
| NFTCycleRewards | `0x625a45136d448884d63965ed2dcc5e051bfb4a6d` |
| StrategyHybridAccumulator | `0x6fde150ff3cb59f32d3526ec3d703abdd387eef6` |

### Mock Tokens

| Token | Address | Decimals |
|---|---|---|
| USDC | `0x348e428E72893f6c756Cc3DDC04113b805b3b5D5` | 6 |
| WBTC | `0xef138d9c24742bF590dEf3f7706b345637fd4aeb` | 8 |
| aWBTC | `0x3E471D735987BD1e87129A22228B03bA04Dd7FC8` | 8 |
| aUSDC | `0xa7AE376Ef7E75f60D16ACf360852670B8da42b2A` | 6 |

## Verified Source Code

All 4 implementations verified on Blockscout:
- [Vault](https://eth-sepolia.blockscout.com/address/0xd836cb694944f879f3283d94528f41d1355b779d)
- [Oracle](https://eth-sepolia.blockscout.com/address/0x09b6bebca45a191de387d1461a2ddd04dc8477ef)
- [NFT](https://eth-sepolia.blockscout.com/address/0x625a45136d448884d63965ed2dcc5e051bfb4a6d)
- [Strategy](https://eth-sepolia.blockscout.com/address/0x6fde150ff3cb59f32d3526ec3d703abdd387eef6)

## Roles

### Safe Multisig: `0x17046a5927beBF2a015f6185A224862f677dDfa4`

| Contract | Roles |
|---|---|
| Vault | DEFAULT_ADMIN, OPERATOR, STRATEGIST |
| Oracle | DEFAULT_ADMIN, KEEPER |
| NFT | DEFAULT_ADMIN, MINTER |
| Strategy | DEFAULT_ADMIN, OPERATOR |

### Deployer: `0x490CE9212cf474a5A73936a8d25b5Ef46751a58f`
Same roles as multisig (for testing). To be revoked before mainnet.

### Contract-to-contract
- Oracle → Strategy: OPERATOR_ROLE (for auto resetCycle on ATH)
- Strategy → NFT: MINTER_ROLE (for cycle-end NFT mints)

## Initial State
- ATH: $90,000
- Deployer holds: 100,000 USDC + 5 WBTC (mock)
- Vault holds: 4 aWBTC + 15,000 aUSDC (simulating Aave positions)
- Cycle: #0, active

## Chainlink
- BTC/USD Feed: `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43`
- VRF Coordinator: `0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625`
- VRF Subscription: needs to be created for NFT minting
