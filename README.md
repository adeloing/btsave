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
