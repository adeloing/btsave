# Turbo Paper Boat Vault — Smart Contracts

ERC-4626 tokenized vault implementing the **Hybrid ZERO-LIQ Aggressive Accumulator** strategy on Ethereum.

## Architecture

```
User → deposit/withdraw (USDC) → TurboPaperBoatVault (ERC-4626 UUPS)
├── TPB shares (transferable ERC-20)
├── OracleManager (Chainlink BTC/USD + Automation)
│   └── ATH detection → auto cycle reset
└── StrategyHybridAccumulator (UUPS)
    ├── AaveV3 adapter (82% WBTC + 15% USDC collateral)
    ├── Deribit operator (3% USDC hedge — off-chain via Multisig)
    └── Rebalancing (82/15/3 target allocation)

NFTCycleRewards (ERC-721 UUPS + Chainlink VRF)
└── 1 NFT per cycle per eligible holder (min 100 USDC avg balance)
    └── Random tier: Bronze / Silver / Gold / Platinum
```

## Contracts

| Contract | Description |
|---|---|
| `TurboPaperBoatVault.sol` | ERC-4626 vault with management (1%/yr) + performance fees (15%), timelock, emergency functions |
| `OracleManager.sol` | Chainlink BTC/USD oracle, ATH tracking, redemption window logic |
| `StrategyHybridAccumulator.sol` | Strategy logic, cycle management, Aave/Deribit allocation (UUPS) |
| `NFTCycleRewards.sol` | ERC-721 cycle NFTs with Chainlink VRF random tier assignment |
| `interfaces/IInterfaces.sol` | Shared interfaces |

## Key Features

- **Redemption window**: open only when BTC price is within [ATH-5%, ATH] after a cycle reset
- **Cycle**: starts at lock → ends at new ATH (full unwind + reset 82/15/3 + mint NFT)
- **Fees**: 1% management/yr + 15% performance (high-water mark). 40% of perf fees to NFT holders
- **Security**: UUPS upgradeable, pausable, 24h timelock on critical actions, emergency withdraw
- **Roles**: Safe Multisig 2/3 — DEFAULT_ADMIN + STRATEGIST + OPERATOR

## Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install

# Build
forge build

# Test
forge test -vvv

# Deploy to Sepolia
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
```

## ⚠️ Trust Assumptions

Deribit hedging (3% allocation + all shorts/puts) is managed **off-chain** via Safe Multisig 2/3. This is not trustless — users trust the multisig operators for the Deribit component.

## Strategy

See `../strategy-hybrid.json` for the full strategy specification (v2.0 — 82/15/3).

## License

MIT
