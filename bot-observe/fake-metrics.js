#!/usr/bin/env node
/**
 * Fake mid-cycle metrics for Grafana demo.
 * Replaces lsm-bot-observe temporarily.
 * Run on port 9101 (same as real bot).
 */
const { Registry, Counter, Gauge, Histogram, collectDefaultMetrics } = require('prom-client');
const express = require('express');

const register = new Registry();
collectDefaultMetrics({ register });

// --- Counters (monotonic, seeded) ---
const txProposed = new Counter({ name: 'lsm_tx_proposed_total', help: 'Total tx proposed', registers: [register] });
const txExecuted = new Counter({ name: 'lsm_tx_executed_total', help: 'Total tx executed', registers: [register] });
const txRejected = new Counter({ name: 'lsm_tx_rejected_total', help: 'Total tx rejected', registers: [register] });
const botApprovals = new Counter({ name: 'lsm_bot_approvals', help: 'Bot approvals', labelNames: ['bot'], registers: [register] });
const botRejection = new Counter({ name: 'lsm_bot_rejection', help: 'Rejections by rule', labelNames: ['bot', 'rule'], registers: [register] });

const botLatency = new Histogram({
  name: 'lsm_bot_approval_latency_seconds', help: 'Latency', labelNames: ['bot'],
  buckets: [0.5, 1, 2, 3, 5, 10, 15, 30], registers: [register]
});

// --- Gauges ---
const killSwitch = new Gauge({ name: 'lsm_kill_switch_active', help: 'Kill switch', registers: [register] });
const dailyTx = new Gauge({ name: 'lsm_daily_tx_count', help: 'Daily tx', registers: [register] });
const dailyBorrow = new Gauge({ name: 'lsm_daily_borrow_volume_usdc', help: 'Daily borrow vol', registers: [register] });
const dailySwap = new Gauge({ name: 'lsm_daily_swap_volume_usdc', help: 'Daily swap vol', registers: [register] });
const hf = new Gauge({ name: 'aave_health_factor', help: 'HF', registers: [register] });
const gas = new Gauge({ name: 'eth_gas_price_gwei', help: 'Gas', registers: [register] });
const heartbeat = new Gauge({ name: 'lsm_bot_last_heartbeat', help: 'Last heartbeat', labelNames: ['bot'], registers: [register] });

// Seed counters (mid-cycle: ~47 proposals, 38 executed, 9 rejected)
txProposed.inc(47);
txExecuted.inc(38);
txRejected.inc(9);
botApprovals.labels('A').inc(42);
botApprovals.labels('B').inc(39);
botApprovals.labels('C').inc(35);
botRejection.labels('A', 'R3_target').inc(2);
botRejection.labels('B', 'R5_selector').inc(1);
botRejection.labels('A', 'R7_approve').inc(1);
botRejection.labels('C', 'R12_daily_borrow').inc(2);
botRejection.labels('B', 'R14_gas').inc(1);
botRejection.labels('A', 'R5_gas_too_high').inc(1);
botRejection.labels('C', 'R2_target_not_whitelisted').inc(1);

// Seed latency histogram
for (let i = 0; i < 25; i++) botLatency.labels('A').observe(0.8 + Math.random() * 1.5);
for (let i = 0; i < 22; i++) botLatency.labels('B').observe(1.2 + Math.random() * 2);
for (let i = 0; i < 18; i++) botLatency.labels('C').observe(1.5 + Math.random() * 3);

// Static state
killSwitch.set(0);
dailyTx.set(6);

// Jitter gauges every 10s
setInterval(() => {
  hf.set(1.83 + Math.random() * 0.09);           // 1.83-1.92
  gas.set(14 + Math.random() * 12);               // 14-26 gwei
  dailyBorrow.set(37440 + Math.random() * 5000);  // ~37-42k
  dailySwap.set(24960 + Math.random() * 3000);    // ~25-28k
  heartbeat.labels('BotA').set(Date.now() / 1000);

  // Slow counter growth (~1 every 2 min)
  if (Math.random() < 0.08) {
    txProposed.inc();
    if (Math.random() < 0.82) {
      txExecuted.inc();
      const bot = ['A','B','C'][Math.floor(Math.random()*3)];
      botApprovals.labels(bot).inc();
      botLatency.labels(bot).observe(0.5 + Math.random() * 4);
    } else {
      txRejected.inc();
      const rules = ['R3_target','R5_selector','R7_approve','R12_daily_borrow','R14_gas'];
      const bot = ['A','B','C'][Math.floor(Math.random()*3)];
      botRejection.labels(bot, rules[Math.floor(Math.random()*rules.length)]).inc();
    }
  }
}, 10_000);

const app = express();
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});
app.get('/health', (req, res) => res.json({ status: 'ok', mode: 'demo-midcycle' }));
app.listen(9101, '0.0.0.0', () => console.log('🎭 Fake mid-cycle metrics on :9101'));
