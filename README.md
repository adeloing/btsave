# ⚡ Hedge — BTC Hedging Strategy

3-process system for BTC position management during market corrections.

## Architecture

### P1 — Collateral Management (AAVE)
Sell 0.1 BTC per 5% step down, cash → USDT collateral on AAVE.

### P2 — Accumulation via Borrowing (AAVE)
Borrow USDT at each step, buy 0.1 BTC. Profit ~0.95 BTC per full cycle.

### P3 — Execution Hedge (Deribit Perps Grid)
Sliding window grid on BTC_USDC-PERPETUAL. Always 4 orders: 2 BUY + 2 SELL.

## Components

| Directory | Description |
|-----------|-------------|
| `dashboard/` | Real-time hedge dashboard (Express, port 3001) — AAVE positions, Deribit orders, BTC chart |
| `grid-ws/` | WebSocket monitor — real-time fill detection + automatic grid repositioning |
| `simulators/` | Strategy simulators — v1 (options, deprecated) + v2 (perps grid) |

## Parameters
- **ATH**: 126,000 USD
- **PAS**: 6,300 USD (5%)
- **Steps**: 19
- **Size**: 0.1 BTC/step
- **Instrument**: BTC_USDC-PERPETUAL

## Grid Logic (Sliding Window)
- When BUY fills (price ↑): add BUY one step higher + SELL at crossed step, cancel furthest SELL
- When SELL fills (price ↓): add SELL one step lower + BUY at crossed step, cancel furthest BUY
- Always maintains 2 BUY + 2 SELL

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
