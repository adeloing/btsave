/**
 * LSM Bot — Phase 1 (Observe-Only)
 * 
 * Watches TxProposed events on the LimitedSignerModule.
 * Simulates transactions, logs approve/reject decisions.
 * Does NOT actually sign or call approveTx().
 * Exposes Prometheus metrics on :9100/metrics
 */

const { ethers } = require('ethers');
const { Registry, Counter, Gauge, Histogram, collectDefaultMetrics } = require('prom-client');
const express = require('express');
const fs = require('fs');

// ============================================================
// Config
// ============================================================
const RPC_URL = process.env.RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const MODULE_ADDRESS = '0x40f7b06433f27B9C9C24fD5d60F2816F9344e04E';
const AAVE_POOL_ADDRESS = '0x9266cBf2212E6A31CCAb3c60553d41613Cb0f93D';
const BOT_NAME = process.env.BOT_NAME || 'BotA';
const METRICS_PORT = process.env.METRICS_PORT || 9101;
const HEARTBEAT_INTERVAL = 10_000; // 10s

// ============================================================
// ABI
// ============================================================
const MODULE_ABI = JSON.parse(fs.readFileSync(__dirname + '/module-abi.json', 'utf8'));

// ============================================================
// Prometheus Metrics
// ============================================================
const register = new Registry();
collectDefaultMetrics({ register });

const txProposedTotal = new Counter({
  name: 'lsm_tx_proposed_total',
  help: 'Total transactions proposed',
  registers: [register],
});

const txExecutedTotal = new Counter({
  name: 'lsm_tx_executed_total',
  help: 'Total transactions executed',
  registers: [register],
});

const txRejectedTotal = new Counter({
  name: 'lsm_tx_rejected_total',
  help: 'Total transactions rejected',
  registers: [register],
});

const botApprovals = new Counter({
  name: 'lsm_bot_approvals',
  help: 'Bot approval decisions (observe-only)',
  labelNames: ['bot'],
  registers: [register],
});

const botRejections = new Counter({
  name: 'lsm_bot_rejection',
  help: 'Bot rejection decisions by rule',
  labelNames: ['bot', 'rule'],
  registers: [register],
});

const botApprovalLatency = new Histogram({
  name: 'lsm_bot_approval_latency_seconds',
  help: 'Latency from proposal to bot decision',
  labelNames: ['bot'],
  buckets: [0.5, 1, 2, 3, 5, 10, 15, 30],
  registers: [register],
});

const killSwitchActive = new Gauge({
  name: 'lsm_kill_switch_active',
  help: 'Whether kill switch is active',
  registers: [register],
});

const dailyTxCount = new Gauge({
  name: 'lsm_daily_tx_count',
  help: 'Daily transaction count',
  registers: [register],
});

const dailyBorrowVolume = new Gauge({
  name: 'lsm_daily_borrow_volume_usdc',
  help: 'Daily borrow volume in USDC',
  registers: [register],
});

const dailySwapVolume = new Gauge({
  name: 'lsm_daily_swap_volume_usdc',
  help: 'Daily swap volume in USDC',
  registers: [register],
});

const healthFactor = new Gauge({
  name: 'aave_health_factor',
  help: 'Current Aave health factor',
  registers: [register],
});

const gasPrice = new Gauge({
  name: 'eth_gas_price_gwei',
  help: 'Current gas price in gwei',
  registers: [register],
});

const botLastHeartbeat = new Gauge({
  name: 'lsm_bot_last_heartbeat',
  help: 'Timestamp of last bot heartbeat',
  labelNames: ['bot'],
  registers: [register],
});

// ============================================================
// Main
// ============================================================
async function main() {
  console.log(`🤖 [${BOT_NAME}] LSM Observer starting...`);
  console.log(`   Module: ${MODULE_ADDRESS}`);
  console.log(`   RPC: ${RPC_URL}`);
  console.log(`   Metrics: http://0.0.0.0:${METRICS_PORT}/metrics`);
  console.log(`   Mode: OBSERVE-ONLY (Phase 1)\n`);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const module = new ethers.Contract(MODULE_ADDRESS, MODULE_ABI, provider);

  // --- Metrics HTTP server ---
  const app = express();
  app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  });
  app.get('/health', (req, res) => res.json({ status: 'ok', bot: BOT_NAME, mode: 'observe-only' }));
  app.listen(METRICS_PORT, '0.0.0.0');

  // --- Poll for events (every 5s) ---
  let lastBlock = await provider.getBlockNumber();
  console.log(`   Starting from block: ${lastBlock}`);

  setInterval(async () => {
    try {
      const currentBlock = await provider.getBlockNumber();
      if (currentBlock <= lastBlock) return;

      // Query TxProposed events
      const proposedFilter = module.filters.TxProposed();
      const proposedEvents = await module.queryFilter(proposedFilter, lastBlock + 1, currentBlock);

      for (const event of proposedEvents) {
        const receiveTime = Date.now();
        const [txHash, keeper, to, selector] = event.args;
        txProposedTotal.inc();

        console.log(`\n📥 [${new Date().toISOString()}] TxProposed (block ${event.blockNumber})`);
        console.log(`   Hash:     ${txHash}`);
        console.log(`   Keeper:   ${keeper}`);
        console.log(`   Target:   ${to}`);
        console.log(`   Selector: ${selector}`);

        try {
          const decision = await validateTransaction(module, provider, txHash, to, selector);
          const latencyMs = Date.now() - receiveTime;

          botApprovalLatency.labels(BOT_NAME).observe(latencyMs / 1000);

          if (decision.approved) {
            botApprovals.labels(BOT_NAME).inc();
            console.log(`   ✅ WOULD APPROVE (${latencyMs}ms)`);
            console.log(`   Reason: All ${decision.checksRun} checks passed`);
          } else {
            txRejectedTotal.inc();
            botRejections.labels(BOT_NAME, decision.failedRule).inc();
            console.log(`   ❌ WOULD REJECT (${latencyMs}ms)`);
            console.log(`   Rule: ${decision.failedRule}`);
            console.log(`   Reason: ${decision.reason}`);
          }
        } catch (err) {
          console.error(`   ⚠️ Error validating: ${err.message}`);
          txRejectedTotal.inc();
          botRejections.labels(BOT_NAME, 'ERROR').inc();
        }
      }

      // Query TxExecuted events
      const execFilter = module.filters.TxExecuted();
      const execEvents = await module.queryFilter(execFilter, lastBlock + 1, currentBlock);
      for (const event of execEvents) {
        const [txHash, to, success] = event.args;
        txExecutedTotal.inc();
        console.log(`\n⚡ [${new Date().toISOString()}] TxExecuted (block ${event.blockNumber})`);
        console.log(`   Hash: ${txHash} | Target: ${to} | Success: ${success}`);
      }

      // Query KillSwitch events
      const killOnFilter = module.filters.KillSwitchActivated();
      const killOnEvents = await module.queryFilter(killOnFilter, lastBlock + 1, currentBlock);
      for (const event of killOnEvents) {
        killSwitchActive.set(1);
        console.log(`\n🔴 [${new Date().toISOString()}] KILL SWITCH ACTIVATED by ${event.args[0]}`);
      }

      const killOffFilter = module.filters.KillSwitchDeactivated();
      const killOffEvents = await module.queryFilter(killOffFilter, lastBlock + 1, currentBlock);
      for (const event of killOffEvents) {
        killSwitchActive.set(0);
        console.log(`\n🟢 [${new Date().toISOString()}] Kill switch deactivated by ${event.args[0]}`);
      }

      lastBlock = currentBlock;
    } catch (err) {
      console.error(`❗ Polling error: ${err.message}`);
    }
  }, 5000);

  // --- Periodic status polling ---
  setInterval(async () => {
    try {
      botLastHeartbeat.labels(BOT_NAME).set(Date.now() / 1000);

      // Module state
      const killed = await module.killed();
      killSwitchActive.set(killed ? 1 : 0);

      const [txCount, borrowVol, swapVol] = await module.getDailyStats();
      dailyTxCount.set(Number(txCount));
      dailyBorrowVolume.set(Number(borrowVol));
      dailySwapVolume.set(Number(swapVol));

      // Gas price
      const feeData = await provider.getFeeData();
      if (feeData.gasPrice) {
        gasPrice.set(Number(feeData.gasPrice / 1_000_000_000n));
      }

      // Health factor from mock Aave
      const aavePool = new ethers.Contract(AAVE_POOL_ADDRESS, [
        'function getUserAccountData(address) view returns (uint256,uint256,uint256,uint256,uint256,uint256)'
      ], provider);
      const data = await aavePool.getUserAccountData(MODULE_ADDRESS);
      const hf = Number(data[5]) / 1e18;
      healthFactor.set(hf);

    } catch (err) {
      console.error(`❗ Heartbeat error: ${err.message}`);
    }
  }, HEARTBEAT_INTERVAL);

  console.log('👁️  Listening for events...\n');
}

// ============================================================
// Validation logic (observe-only)
// ============================================================
async function validateTransaction(module, provider, txHash, to, selector) {
  let checksRun = 0;

  // R4: Kill switch
  checksRun++;
  const killed = await module.killed();
  if (killed) return { approved: false, failedRule: 'R4', reason: 'Module is killed', checksRun };

  // R2: Target whitelisted
  checksRun++;
  const targetAllowed = await module.allowedTargets(to);
  if (!targetAllowed) return { approved: false, failedRule: 'R2', reason: 'Target not whitelisted', checksRun };

  // R3: Selector whitelisted
  checksRun++;
  const selectorAllowed = await module.allowedSelectors(to, selector);
  if (!selectorAllowed) return { approved: false, failedRule: 'R3', reason: 'Selector not allowed', checksRun };

  // R5: Gas price
  checksRun++;
  const feeData = await provider.getFeeData();
  const maxGas = await module.maxGasPrice();
  if (feeData.gasPrice && feeData.gasPrice > maxGas) {
    return { approved: false, failedRule: 'R5', reason: `Gas ${feeData.gasPrice} > max ${maxGas}`, checksRun };
  }

  // R14: Health factor
  checksRun++;
  const minHF = await module.minHealthFactor();
  const aavePool = new ethers.Contract(AAVE_POOL_ADDRESS, [
    'function getUserAccountData(address) view returns (uint256,uint256,uint256,uint256,uint256,uint256)'
  ], provider);
  const userData = await aavePool.getUserAccountData(await module.safe());
  const currentHF = userData[5];
  if (currentHF !== ethers.MaxUint256 && currentHF < minHF) {
    return { approved: false, failedRule: 'R14', reason: `HF ${currentHF} < min ${minHF}`, checksRun };
  }

  // R12: Daily tx limit
  checksRun++;
  const [txCount] = await module.getDailyStats();
  const maxDaily = await module.maxDailyTx();
  if (txCount >= maxDaily) {
    return { approved: false, failedRule: 'R12', reason: `Daily tx count ${txCount} >= max ${maxDaily}`, checksRun };
  }

  return { approved: true, checksRun };
}

main().catch(console.error);
