# ⚡ Hedge — BTC Hedging Strategy

3-process system for BTC position management across market cycles.

## Architecture

### P1 — Collateral Management (AAVE)
- **Price drops**: Sell 0.1 BTC per 5% step down → USDT added as collateral on AAVE
- **Price rises**: Buy 0.1 BTC per 5% step up → rebuild BTC collateral on AAVE
- Symmetrical: same 0.1 BTC size in both directions at each step crossing

### P2 — Accumulation via Borrowing (AAVE)
- At each step down: borrow USDT equivalent, buy 0.1 BTC → accumulate
- At ATH return: sell accumulated BTC, repay debt, keep profit (~0.95 BTC per full cycle)
- First crossing of a step = 1 atomic tx (borrow only, no hedge needed)

### P3 — Execution Hedge (Deribit Perps Grid)
- Sliding window grid on BTC_USDC-PERPETUAL — always 4 orders: 2 BUY + 2 SELL
- Hedges price risk during on-chain swap execution delay (~hours)
- Grid captures ~$100 per oscillation per step (+0.10-0.16 BTC/year)

## Components

| Directory | Description |
|-----------|-------------|
| `dashboard/` | Real-time hedge dashboard (Express, port 3001) — AAVE positions, Deribit orders, BTC chart, close button |
| `grid-ws/` | WebSocket monitor — real-time fill detection + automatic grid repositioning |
| `simulators/` | Strategy simulators — v1 (options, deprecated) + v2 (perps grid) |

## Parameters
- **ATH**: 126,000 USD
- **PAS**: 6,300 USD (5%)
- **Steps**: 19
- **Size**: 0.1 BTC/step (both directions)
- **Instrument**: BTC_USDC-PERPETUAL

## Grid Capture
- **$100 net par crossing** (0.1 BTC × spread $1,000, net après équilibrage du sliding window)
- Les gains sont conservés en BTC pour revente à l'ATH

### Estimations de gains P3 — 9 scénarios

| Durée | Volatilité | Cross/mois | Total | Gain $ | BTC accum. | Valeur @ATH |
|-------|-----------|-----------|-------|--------|-----------|------------|
| **3 mois** | Basse (30%) | 2.8 | 9 | $900 | 0.0125 ₿ | **$1,575** |
| **3 mois** | Moyenne (55%) | 5.2 | 16 | $1,600 | 0.0222 ₿ | **$2,800** |
| **3 mois** | Haute (85%) | 8.1 | 24 | $2,400 | 0.0333 ₿ | **$4,200** |
| **10 mois** | Basse (30%) | 3.4 | 34 | $3,400 | 0.0400 ₿ | **$5,040** |
| **10 mois** | Moyenne (55%) | 6.2 | 62 | $6,200 | 0.0729 ₿ | **$9,191** |
| **10 mois** | Haute (85%) | 9.5 | 95 | $9,500 | 0.1118 ₿ | **$14,082** |
| **18 mois** | Basse (30%) | 3.9 | 70 | $7,000 | 0.0714 ₿ | **$9,000** |
| **18 mois** | Moyenne (55%) | 7.1 | 128 | $12,800 | 0.1306 ₿ | **$16,457** |
| **18 mois** | Haute (85%) | 11.0 | 197 | $19,700 | 0.2010 ₿ | **$25,329** |

> **Hypothèses** : capture $100 net/crossing · gains convertis en BTC au prix moyen de la période (3m→$72k, 10m→$85k, 18m→$98k) · revendus à ATH $126k · frais Deribit et funding rate négligés · crossings estimés via random walk ajusté (facteur 0.55)

**Cas moyen réaliste** (10 mois, vol moyenne) : **~0.07 BTC → ~$9,200 @ATH** (×1.48 vs garder en $)

## Grid Logic (Sliding Window)
- Always maintains 2 BUY (above price) + 2 SELL (below price)
- On fill, recalculate target window: 2 nearest buy_levels above + 2 nearest sell_levels below current price
- BUY triggers (price ↑) → only adds a new BUY further up. Sells stay.
- SELL triggers (price ↓) → only adds a new SELL further down. Buys stay.

## Deployment
```bash
# Dashboard
cd dashboard && npm install
sudo systemctl enable --now hedge-dashboard

# Grid WebSocket monitor
cd grid-ws && npm install
sudo systemctl enable --now deribit-grid-ws
```

## Live
- Dashboard: https://ratpoison2.duckdns.org/hedge/

---
Built by xou & Kei ⚡
