const express = require('express');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const FUNDING_RESET_FILE = path.join(__dirname, 'funding-reset.json');
function getFundingReset() {
  try { return JSON.parse(fs.readFileSync(FUNDING_RESET_FILE, 'utf8')); }
  catch { return { resetTimestamp: 0, resetTotal: 0 }; }
}
function setFundingReset(data) {
  fs.writeFileSync(FUNDING_RESET_FILE, JSON.stringify(data, null, 2));
}
const session = require('express-session');
const app = express();
const PORT = 3001;

// === AUTH CONFIG ===
const SESSION_SECRET = 'btsave-kei-' + crypto.randomBytes(8).toString('hex');
const USERS = {
  xou: { hash: crypto.createHash('sha256').update('REDACTED_PASSWORD').digest('hex'), role: 'admin' },
  mael: { hash: crypto.createHash('sha256').update('mael').digest('hex'), role: 'readonly' }
};

app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, maxAge: 30 * 24 * 3600 * 1000 }
}));

app.use(express.urlencoded({ extended: false }));

app.post('/auth/login', (req, res) => {
  const { username, password } = req.body;
  const hash = crypto.createHash('sha256').update(password || '').digest('hex');
  if (USERS[username] && USERS[username].hash === hash) {
    req.session.user = username;
    req.session.role = USERS[username].role;
    const basePath = req.baseUrl || '';
    res.redirect(basePath + '/');
  } else {
    res.redirect('login.html?error=1');
  }
});

app.get('/auth/logout', (req, res) => {
  req.session.destroy(() => res.redirect('login.html'));
});

function requireAuth(req, res, next) {
  if (req.path === '/login.html' || req.path.startsWith('/auth/') || req.path === '/logo.svg') return next();
  if (req.session?.user) return next();
  if (req.path.startsWith('/api/')) return res.status(401).json({ error: 'Not authenticated' });
  res.redirect('login.html');
}
app.use(requireAuth);

// Deribit API
const DERIBIT_ID = 'hvWM-oCG';
const DERIBIT_SECRET = 'FRkOz3Zqo0LCIKnyxTfUZ15aWgZLbmTJid9k4ATU720';

// AAVE V3 on-chain
const AAVE_WALLET = '0x5F8E0020C3164fB7EB170D7345672F6948Ca0FF4';
const ETH_RPC = 'https://eth.llamarpc.com';
const AAVE_POOL = '0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2';
const AWBTC = '0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8';
const AUSDT = '0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a';
const DEBT_USDT = '0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8';
const AUSDC = '0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c';
const DEBT_USDC = '0x72E95b8931767C79bA4EeE721354d6E99a61D004';

// === Strategy constants ===
const ATH = 126000;
const WBTC_START = 3.90;
const STEP_SIZE = ATH * 0.05; // 6300
const BUFFER_USDC_AAVE = WBTC_START * ATH * 0.18;
const USDC_DERIBIT_TARGET = WBTC_START * ATH * 0.03;
const BORROW_PER_STEP = WBTC_START * 3200; // 12480
const SHORT_PER_STEP = +(WBTC_START * 0.0244).toFixed(3); // 0.095

// === Cache ===
let cache = { data: null, ts: 0 };
const CACHE_TTL = 15000;

let deribitToken = { token: null, expiresAt: 0 };

async function getDeribitToken() {
  if (deribitToken.token && Date.now() < deribitToken.expiresAt - 30000) {
    return deribitToken.token;
  }
  const auth = await deribit('public/auth', { grant_type: 'client_credentials', client_id: DERIBIT_ID, client_secret: DERIBIT_SECRET });
  deribitToken.token = auth.result.access_token;
  deribitToken.expiresAt = Date.now() + (auth.result.expires_in || 900) * 1000;
  return deribitToken.token;
}

function deribit(method, params = {}, token) {
  return new Promise((resolve, reject) => {
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = 'Bearer ' + token;
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
    const req = https.request({ hostname: 'www.deribit.com', path: '/api/v2/' + method, method: 'POST', headers }, res => {
      let d = ''; res.on('data', c => d += c); res.on('end', () => {
        try {
          const parsed = JSON.parse(d);
          if (parsed.error) reject(new Error(parsed.error.message || JSON.stringify(parsed.error)));
          else resolve(parsed);
        } catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

function ethCall(to, data) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', method: 'eth_call', params: [{ to, data }, 'latest'], id: 1 });
    const url = new URL(ETH_RPC);
    const mod = url.protocol === 'https:' ? https : http;
    const req = mod.request({ hostname: url.hostname, path: url.pathname, method: 'POST', headers: { 'Content-Type': 'application/json' } }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch(e) { reject(e); } });
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

function toBig(hex) { return !hex || hex === '0x' || hex === '0x0' ? 0n : BigInt(hex); }

function ethBatch(calls) {
  const batch = calls.map((c, i) => ({ jsonrpc: '2.0', method: 'eth_call', params: [{ to: c.to, data: c.data }, 'latest'], id: i }));
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(batch);
    const url = new URL(ETH_RPC);
    const mod = url.protocol === 'https:' ? https : http;
    const req = mod.request({ hostname: url.hostname, path: url.pathname, method: 'POST', headers: { 'Content-Type': 'application/json' } }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch(e) { reject(e); } });
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

async function fetchAAVE() {
  const addr = AAVE_WALLET.replace('0x', '').toLowerCase();
  const padAddr = '000000000000000000000000' + addr;
  const balOf = '0x70a08231' + padAddr;

  try {
    const results = await ethBatch([
      { to: AAVE_POOL, data: '0xbf92857c' + padAddr },
      { to: AWBTC, data: balOf },
      { to: AUSDT, data: balOf },
      { to: DEBT_USDT, data: balOf },
      { to: AUSDC, data: balOf },
      { to: DEBT_USDC, data: balOf },
    ]);

    results.sort((a, b) => a.id - b.id);

    const h = results[0].result.slice(2);
    const chunks = [];
    for (let i = 0; i < h.length; i += 64) chunks.push(BigInt('0x' + h.slice(i, i + 64)));

    return {
      totalCollateralUSD: Number(chunks[0]) / 1e8,
      totalDebtUSD: Number(chunks[1]) / 1e8,
      availableBorrowsUSD: Number(chunks[2]) / 1e8,
      liquidationThreshold: Number(chunks[3]),
      ltv: Number(chunks[4]),
      healthFactor: Number(chunks[5]) / 1e18,
      wbtcBTC: Number(toBig(results[1].result)) / 1e8,
      usdtCol: Number(toBig(results[2].result)) / 1e6,
      debtUSDT: Number(toBig(results[3].result)) / 1e6,
      usdcCol: Number(toBig(results[4].result)) / 1e6,
      debtUSDC: Number(toBig(results[5].result)) / 1e6,
    };
  } catch (e) {
    console.error('AAVE fetch error:', e.message);
    return null;
  }
}

let historyCache = { data: null, ts: 0 };
const HISTORY_TTL = 300000;

async function fetchPriceHistory() {
  if (Date.now() - historyCache.ts < HISTORY_TTL && historyCache.data) return historyCache.data;
  const end = Date.now();
  const start = end - 1 * 86400000; // 24h only
  return new Promise((resolve) => {
    const url = `/api/v2/public/get_tradingview_chart_data?instrument_name=BTC_USDC-PERPETUAL&start_timestamp=${start}&end_timestamp=${end}&resolution=15`;
    https.get({ hostname: 'www.deribit.com', path: url }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => {
        try {
          const r = JSON.parse(d);
          if (r.result && r.result.ticks) {
            historyCache.data = r.result.ticks.map((t, i) => ({
              t, o: r.result.open[i], h: r.result.high[i], l: r.result.low[i], c: r.result.close[i]
            }));
            historyCache.ts = Date.now();
            resolve(historyCache.data);
          } else resolve(historyCache.data || []);
        } catch(e) { resolve(historyCache.data || []); }
      });
    }).on('error', () => resolve(historyCache.data || []));
  });
}

async function fetchEthInfo() {
  try {
    const addr = AAVE_WALLET.toLowerCase();
    const batch = [
      { jsonrpc: '2.0', method: 'eth_getBalance', params: [addr, 'latest'], id: 0 },
      { jsonrpc: '2.0', method: 'eth_gasPrice', params: [], id: 1 }
    ];
    const body = JSON.stringify(batch);
    const url = new URL(ETH_RPC);
    const mod = url.protocol === 'https:' ? https : http;
    const results = await new Promise((resolve, reject) => {
      const req = mod.request({ hostname: url.hostname, path: url.pathname, method: 'POST', headers: { 'Content-Type': 'application/json' } }, res => {
        let d = ''; res.on('data', c => d += c);
        res.on('end', () => { try { resolve(JSON.parse(d)); } catch(e) { reject(e); } });
      });
      req.on('error', reject);
      req.write(body); req.end();
    });
    results.sort((a, b) => a.id - b.id);
    const ethBalance = Number(toBig(results[0].result)) / 1e18;
    const gasPriceWei = Number(toBig(results[1].result));
    const gasPriceGwei = gasPriceWei / 1e9;
    const swapCostETH = (gasPriceWei * 150000) / 1e18;
    let ethPriceUSD = 0;
    try {
      const ethTicker = await new Promise((resolve, reject) => {
        https.get('https://www.deribit.com/api/v2/public/ticker?instrument_name=ETH-PERPETUAL', res => {
          let d = ''; res.on('data', c => d += c);
          res.on('end', () => { try { resolve(JSON.parse(d)); } catch(e) { reject(e); } });
        }).on('error', reject);
      });
      ethPriceUSD = ethTicker.result?.last_price || 0;
    } catch(e) {}
    const swapCostUSD = swapCostETH * ethPriceUSD;
    return { ethBalance: +ethBalance.toFixed(6), gasPriceGwei: +gasPriceGwei.toFixed(1), swapCostETH: +swapCostETH.toFixed(6), swapCostUSD: +swapCostUSD.toFixed(2), ethPriceUSD: +ethPriceUSD.toFixed(0) };
  } catch (e) {
    console.error('ETH info error:', e.message);
    return null;
  }
}

process.on('uncaughtException', (err) => { console.error('UNCAUGHT:', err.message); });
process.on('unhandledRejection', (err) => { console.error('UNHANDLED:', err.message || err); });

app.use(express.static('public'));

async function fetchAllData() {
  const token = await getDeribitToken();

  const [ticker, account, ordersRes, posRes, posResBTC, tradesRes, settlementsRes, aave, historyPrices, ethInfo] = await Promise.all([
    deribit('public/ticker', { instrument_name: 'BTC_USDC-PERPETUAL' }, token),
    deribit('private/get_account_summary', { currency: 'USDC' }, token),
    deribit('private/get_open_orders_by_currency', { currency: 'USDC' }, token),
    deribit('private/get_positions', { currency: 'USDC' }, token),
    deribit('private/get_positions', { currency: 'BTC' }, token).catch(() => ({ result: [] })),
    deribit('private/get_user_trades_by_currency', { currency: 'USDC', kind: 'future', count: 100, sorting: 'desc' }, token).catch(() => ({ result: { trades: [] } })),
    deribit('private/get_settlement_history_by_currency', { currency: 'USDC', type: 'settlement', count: 1000 }, token).catch(() => ({ result: { settlements: [] } })),
    fetchAAVE(),
    fetchPriceHistory(),
    fetchEthInfo(),
  ]);

  // Mock LSM status (integrating data here instead of separate endpoint)
  const lsmStatus = {
    active: true,
    killed: false,
    botThreshold: 2,
    maxGasPrice: 80,
    minHealthFactor: 1.55,
    dailyTxCount: 0,
    maxDailyTx: 20,
    proposalTTL: 1800,
    lastExecution: null,
    moduleAddress: '0x40f7b06433f27B9C9C24fD5d60F2816F9344e04E',
    network: 'sepolia',
    grafanaUrl: 'https://ratpoison2.duckdns.org/grafana/'
  };

  const price = ticker.result.last_price;
  const equity = account.result.equity;
  const available = account.result.available_funds;

  const orders = (ordersRes.result || []).map(o => ({
    direction: o.direction, price: o.price, amount: o.amount,
    type: o.order_type, label: o.label || '', state: o.order_state,
    trigger: o.trigger_price || null
  }));

  // Split positions by kind
  const allPositions = [...(posRes.result || []), ...(posResBTC.result || [])].filter(p => p.size !== 0);
  
  const futurePositions = allPositions.filter(p => p.kind === 'future').map(p => ({
    instrument: p.instrument_name, size: p.size_currency || p.size, direction: p.direction,
    avgPrice: p.average_price, pnl: p.floating_profit_loss, leverage: p.leverage,
    kind: 'future'
  }));

  const optionPositions = allPositions.filter(p => p.kind === 'option').map(p => {
    // Parse instrument name: e.g. BTC-28MAR26-80000-P
    const parts = p.instrument_name.split('-');
    const expiry = parts[1] || '';
    const strike = parseFloat(parts[2]) || 0;
    const optionType = parts[3] || ''; // P or C
    return {
      instrument: p.instrument_name, size: p.size || p.size_currency, direction: p.direction,
      avgPrice: p.average_price, pnl: p.floating_profit_loss,
      kind: 'option', optionType,
      strike, expiry,
      markPrice: p.mark_price || 0,
      delta: p.delta || 0,
      theta: p.theta || 0,
      vega: p.vega || 0,
      indexPrice: p.index_price || 0,
    };
  });

  // Strategy: compute steps
  const steps = Array.from({length: 19}, (_, i) => {
    const prix = ATH - (i+1) * STEP_SIZE;
    return { step: i+1, prix: +prix.toFixed(0) };
  });

  let currentStep = 0;
  for (const s of steps) {
    if (price < s.prix) currentStep = s.step;
  }

  // Répartition live
  let repartition = null;
  if (aave) {
    const wbtcUSD = aave.wbtcBTC * price;
    const usdcAAVE = aave.usdtCol + aave.usdcCol; // USDT + USDC collateral on AAVE
    const usdcDeribit = equity; // Deribit equity in USDC
    const totalPortfolio = wbtcUSD + usdcAAVE + usdcDeribit;
    repartition = {
      wbtcPct: +((wbtcUSD / totalPortfolio) * 100).toFixed(1),
      usdcAavePct: +((usdcAAVE / totalPortfolio) * 100).toFixed(1),
      usdcDeribitPct: +((usdcDeribit / totalPortfolio) * 100).toFixed(1),
      totalPortfolioUSD: +totalPortfolio.toFixed(0)
    };
  }

  // ATH breakdown — full picture including Deribit positions
  let athBreakdown = null;
  if (aave) {
    const totalDebtUSDC = aave.debtUSDT + (aave.debtUSDC || 0);
    const debtRepayBtc = totalDebtUSDC / ATH;
    const bufferUSDC = aave.usdcCol + aave.usdtCol;
    const bufferBtc = bufferUSDC / ATH;

    // Deribit: short loss at ATH + equity
    // Short perp: if we close at ATH, loss = size * (ATH - avgPrice) in USDC
    let shortLossUSDC = 0;
    for (const p of futurePositions) {
      if (p.direction === 'sell' && p.avgPrice) {
        shortLossUSDC += Math.abs(p.size) * (ATH - p.avgPrice);
      }
    }
    const shortLossBtc = shortLossUSDC / ATH;

    // Puts are worthless at ATH (strike << ATH), premium already lost in equity
    // Deribit equity (USDC) = net value after all current PnL
    const deribitEquityBtc = equity / ATH;

    const netBtcATH = aave.wbtcBTC + bufferBtc - debtRepayBtc + deribitEquityBtc - shortLossBtc;
    athBreakdown = {
      wbtcStart: WBTC_START,
      currentWbtc: +aave.wbtcBTC.toFixed(4),
      accumulated: +(aave.wbtcBTC - WBTC_START).toFixed(4),
      bufferUSDC: +bufferUSDC.toFixed(0),
      bufferBtc: +bufferBtc.toFixed(4),
      debtRepayBtc: +debtRepayBtc.toFixed(4),
      shortLossUSDC: +shortLossUSDC.toFixed(0),
      shortLossBtc: +shortLossBtc.toFixed(4),
      deribitEquityUSDC: +equity.toFixed(0),
      deribitEquityBtc: +deribitEquityBtc.toFixed(4),
      netBtc: +netBtcATH.toFixed(4),
      netUSD: +(netBtcATH * ATH).toFixed(0)
    };
  }

  // Funding rate gains
  const settlements = (settlementsRes.result && settlementsRes.result.settlements) || [];
  const fundingReset = getFundingReset();
  const fundingSettlements = settlements.filter(s => s.position !== 0 && s.timestamp > fundingReset.resetTimestamp);
  let fundingTotal = 0;
  const fundingHistory = [];
  for (const s of fundingSettlements) {
    fundingTotal += s.funding || 0;
    fundingHistory.push({
      timestamp: s.timestamp,
      funding: +(s.funding || 0).toFixed(6),
      position: s.position,
      price: s.index_price,
    });
  }
  // Current funding rate from ticker
  const funding8h = ticker.result.funding_8h || 0;
  // BTC_USDC-PERPETUAL settles once per day at 08:00 UTC
  const fundingAnnualPct = +(funding8h * 365 * 100).toFixed(2);

  // Next settlement countdown
  const now = Date.now();
  const today8 = new Date(); today8.setUTCHours(8, 0, 0, 0);
  let nextSettlement = today8.getTime();
  if (nextSettlement <= now) nextSettlement += 24 * 3600 * 1000;
  const prevSettlement = nextSettlement - 24 * 3600 * 1000;
  const progressPct = +((now - prevSettlement) / (nextSettlement - prevSettlement) * 100).toFixed(1);

  // Estimated next payout: avg funding per settlement × current position factor
  const avgFunding = fundingSettlements.length > 0 ? fundingTotal / fundingSettlements.length : 0;
  // Also compute rate-based estimate: funding_8h * position_notional (but for daily settlement)
  const shortNotional = futurePositions.filter(p => p.direction === 'sell').reduce((s, p) => s + Math.abs(p.size) * price, 0);
  const estNextPayout = shortNotional > 0 ? +(funding8h * shortNotional).toFixed(4) : 0;

  const fundingGains = {
    totalUSDC: +fundingTotal.toFixed(4),
    count: fundingSettlements.length,
    rate8h: funding8h,
    rateAnnualPct: fundingAnnualPct,
    avgPerSettlement: +avgFunding.toFixed(4),
    estNextPayout,
    nextSettlement,
    progressPct,
    history: fundingHistory.slice(0, 20),
    resetTimestamp: fundingReset.resetTimestamp,
  };

  // Determine current zone based on Health Factor (v3 thresholds)
  const pctFromATH = ((price - ATH) / ATH) * 100;
  const hfZone = aave ? aave.healthFactor : 99;
  let currentZone = 'accumulation';
  if (hfZone >= 1.55) currentZone = 'accumulation';
  else if (hfZone >= 1.40) currentZone = 'monitor';
  else if (hfZone >= 1.30) currentZone = 'zone1';
  else if (hfZone >= 1.25) currentZone = 'zone2';
  else if (hfZone >= 1.15) currentZone = 'zone3';
  else currentZone = 'emergency';

  // Compute next step above and below current price
  let nextStepDown = null, nextStepUp = null, currentStepPrice = null;
  for (const s of steps) {
    if (price >= s.prix) { nextStepDown = s; break; }
  }
  for (let i = steps.length - 1; i >= 0; i--) {
    if (price < steps[i].prix) { nextStepUp = steps[i]; break; }
  }
  if (currentStep > 0) currentStepPrice = steps[currentStep - 1].prix;

  // Real-state-aware next actions
  const totalShortBTC = futurePositions.filter(p => p.direction === 'sell').reduce((s, p) => s + Math.abs(p.size), 0);
  const hasPuts = optionPositions.some(p => p.optionType === 'P');
  const putSize = optionPositions.filter(p => p.optionType === 'P').reduce((s, p) => s + Math.abs(p.size), 0);
  const putStrike = optionPositions.filter(p => p.optionType === 'P')[0]?.strike || 0;
  const putExpiry = optionPositions.filter(p => p.optionType === 'P')[0]?.expiry || '';
  const untriggeredStops = orders.filter(o => o.direction === 'sell' && o.trigger);
  const debtUSD = aave ? aave.totalDebtUSD : 0;
  const hf = aave ? aave.healthFactor : 0;
  const usdcAvailable = aave ? (aave.usdcCol || 0) : 0;

  const nextActions = { 
    zone: currentZone, 
    pctFromATH: +pctFromATH.toFixed(1), 
    autoActions: [], 
    manualActions: [], 
    warnings: [], 
    status: [] 
  };

  // Status: show real position state
  nextActions.status.push('HF: ' + hf.toFixed(2) + (hf >= 2.0 ? ' ✅' : hf >= 1.55 ? ' ⚠️' : ' 🚨'));
  nextActions.status.push('Dette: $' + Math.round(debtUSD).toLocaleString('fr-FR'));
  nextActions.status.push('Short perp: ' + totalShortBTC.toFixed(3) + ' BTC');
  if (hasPuts) nextActions.status.push('Puts: ' + putSize.toFixed(2) + '× $' + putStrike.toLocaleString('fr-FR') + ' ' + putExpiry);
  nextActions.status.push('Sell stops: ' + untriggeredStops.length + ' en attente');
  if (usdcAvailable > 0) nextActions.status.push('Buffer USDC AAVE: $' + Math.round(usdcAvailable).toLocaleString('fr-FR'));

  // AUTO ACTIONS (bots via LSM)
  nextActions.autoActions.push('Sell stop grid sur Deribit (' + SHORT_PER_STEP + ' BTC par palier)');
  nextActions.autoActions.push('Monitoring HF continu');
  nextActions.autoActions.push('Kill switch si anomalie détectée');
  nextActions.autoActions.push('Cooldown 300s entre exécutions');
  nextActions.autoActions.push('Gas check ≤ 80 gwei avant TX');

  // MANUAL ACTIONS (human 2/2)
  if (hf < 1.15) {
    // Emergency zone
    nextActions.manualActions.push('🚨 URGENCE — vendre tout + rembourser max');
    if (hasPuts) nextActions.manualActions.push('Vendre TOUS puts restants');
    nextActions.manualActions.push('Rembourser le maximum possible de dette');
  } else if (hf < 1.25) {
    // Zone 3
    nextActions.manualActions.push('Vendre puts restants + rembourser 40% dette');
    if (hasPuts) nextActions.manualActions.push('Vendre 100% puts → repay 40% dette');
  } else if (hf < 1.30) {
    // Zone 2
    nextActions.manualActions.push('Vendre 50% puts + rembourser 25% dette');
    if (hasPuts) nextActions.manualActions.push('Vendre 50% puts → repay 25% dette');
  } else if (hf < 1.40) {
    // Zone 1 - STOP borrowing
    nextActions.manualActions.push('🛑 STOP nouveaux emprunts');
    nextActions.manualActions.push('Monitoring puts pour monétisation');
  } else if (hf < 1.55) {
    // Monitor zone
    nextActions.manualActions.push('Monitor renforcé + manual puts review');
    nextActions.manualActions.push('Borrow USDC sur AAVE (' + BORROW_PER_STEP.toLocaleString('fr-FR') + ' USDC/palier)');
    nextActions.manualActions.push('Swap USDC → WBTC via DeFiLlama');
    nextActions.manualActions.push('Supply aEthWBTC sur AAVE');
  } else {
    // Accumulation normale (HF >= 1.55)
    nextActions.manualActions.push('Borrow USDC sur AAVE (' + BORROW_PER_STEP.toLocaleString('fr-FR') + ' USDC/palier)');
    nextActions.manualActions.push('Swap USDC → WBTC via DeFiLlama');
    nextActions.manualActions.push('Supply aEthWBTC sur AAVE');
    nextActions.manualActions.push('Achat puts OTM sur Deribit');
    nextActions.manualActions.push('Rebalancing à l\'ATH');
  }

  // === PUT OTM recommendation ===
  const wbtcExtra = aave ? aave.wbtcBTC - WBTC_START : 0;
  const wbtcExtraPct = WBTC_START > 0 ? (wbtcExtra / WBTC_START) * 100 : 0;
  // Forward-looking: after next borrow+swap
  const nextSwapBtc = BORROW_PER_STEP / price;
  const wbtcExtraAfterSwap = wbtcExtra + nextSwapBtc;
  const wbtcExtraPctAfterSwap = (wbtcExtraAfterSwap / WBTC_START) * 100;
  const currentPutCoverage = putSize; // BTC covered by current puts
  let putRecommendation = null;

  if (hf >= 1.40) { // No new puts below HF 1.40
    let targetCoveragePct = 0;
    let targetStrikeOTM = 0;
    let targetExpDays = '';

    // Use after-swap values if current is below threshold but next swap crosses it
    const useAfterSwap = wbtcExtraPct < 6 && wbtcExtraPctAfterSwap >= 6 && hf >= 1.40;
    const evalPct = useAfterSwap ? wbtcExtraPctAfterSwap : wbtcExtraPct;
    const evalExtra = useAfterSwap ? wbtcExtraAfterSwap : wbtcExtra;

    if (evalPct >= 24) {
      targetCoveragePct = 100;
      targetStrikeOTM = 21;
      targetExpDays = '30-45j';
    } else if (evalPct >= 14 && hf >= 1.56) {
      targetCoveragePct = 85;
      targetStrikeOTM = 23;
      targetExpDays = '35-50j';
    } else if (evalPct >= 6 && hf >= 1.68) {
      targetCoveragePct = 60;
      targetStrikeOTM = 27;
      targetExpDays = '45-60j';
    }

    // HF adjustments
    if (hf >= 1.40 && hf < 1.55 && targetCoveragePct > 0) {
      targetCoveragePct = 100;
      targetStrikeOTM = Math.min(targetStrikeOTM, 20);
    } else if (hf >= 1.55 && hf < 1.70 && targetCoveragePct > 0) {
      targetCoveragePct = Math.min(targetCoveragePct + 15, 100);
      targetStrikeOTM = Math.max(targetStrikeOTM - 2, 18);
    }

    if (targetCoveragePct > 0) {
      const targetSize = +(evalExtra * targetCoveragePct / 100).toFixed(2);
      const strikePrice = Math.round(price * (1 - targetStrikeOTM / 100) / 1000) * 1000;
      const deficit = +(targetSize - currentPutCoverage).toFixed(2);

      putRecommendation = {
        eligible: true,
        afterSwap: useAfterSwap,
        wbtcExtra: +wbtcExtra.toFixed(4),
        wbtcExtraPct: +wbtcExtraPct.toFixed(1),
        wbtcExtraAfterSwap: +wbtcExtraAfterSwap.toFixed(4),
        wbtcExtraPctAfterSwap: +wbtcExtraPctAfterSwap.toFixed(1),
        targetCoveragePct,
        targetSize,
        currentCoverage: +currentPutCoverage.toFixed(2),
        deficit,
        strikeOTM: targetStrikeOTM,
        strikePrice,
        expiry: targetExpDays,
        needsAction: deficit > 0.05,
        minSizeOk: evalExtra >= 0.20,
      };
    } else {
      // Check if next swap would cross threshold
      let reason = wbtcExtraPct < 6 ? 'WBTC extra < 6% (' + wbtcExtraPct.toFixed(1) + '%)' : 'HF insuffisant pour ce palier';
      if (wbtcExtraPct < 6 && wbtcExtraPctAfterSwap < 6) {
        reason += ' — après prochain swap: ' + wbtcExtraPctAfterSwap.toFixed(1) + '% (toujours < 6%)';
      }
      putRecommendation = {
        eligible: false,
        wbtcExtra: +wbtcExtra.toFixed(4),
        wbtcExtraPct: +wbtcExtraPct.toFixed(1),
        wbtcExtraAfterSwap: +wbtcExtraAfterSwap.toFixed(4),
        wbtcExtraPctAfterSwap: +wbtcExtraPctAfterSwap.toFixed(1),
        reason,
      };
    }
  } else {
    putRecommendation = {
      eligible: false,
      wbtcExtra: +wbtcExtra.toFixed(4),
      wbtcExtraPct: +wbtcExtraPct.toFixed(1),
      reason: 'HF < 1.40 — mode monétisation uniquement',
    };
  }

  // Directional context
  if (nextStepDown) {
    nextActions.autoActions.push('▼ Si $' + nextStepDown.prix.toLocaleString('fr-FR') + ': sell stop ' + SHORT_PER_STEP + ' BTC se déclenche');
  }
  if (nextStepUp) {
    nextActions.autoActions.push('▲ Si $' + nextStepUp.prix.toLocaleString('fr-FR') + ': conserver shorts pour contango');
  }

  return {
    price, ATH, stepSize: STEP_SIZE, currentStep, steps,
    nextStepDown, nextStepUp, currentStepPrice,
    nextActions,
    putRecommendation,
    lsmStatus,
    strategy: {
      name: 'Hybrid ZERO-LIQ + LSM Module v3',
      split: '79/18/3',
      wbtcStart: WBTC_START,
      stepSize: STEP_SIZE,
      bufferUsdcAave: +BUFFER_USDC_AAVE.toFixed(0),
      usdcDeribitTarget: +USDC_DERIBIT_TARGET.toFixed(0),
      borrowPerStep: +BORROW_PER_STEP.toFixed(0),
      shortPerStep: SHORT_PER_STEP,
    },
    repartition,
    currentZone,
    aave: aave ? {
      wbtcBTC: +aave.wbtcBTC.toFixed(8),
      usdtCol: +aave.usdtCol.toFixed(2),
      usdcCol: +aave.usdcCol.toFixed(2),
      debtUSDT: +aave.debtUSDT.toFixed(2),
      debtUSDC: +(aave.debtUSDC || 0).toFixed(2),
      totalCollateralUSD: +aave.totalCollateralUSD.toFixed(2),
      totalDebtUSD: +aave.totalDebtUSD.toFixed(2),
      availableBorrowsUSD: +aave.availableBorrowsUSD.toFixed(2),
      healthFactor: +aave.healthFactor.toFixed(4),
      ltv: aave.ltv,
      liquidationThreshold: aave.liquidationThreshold,
      athBreakdown
    } : null,
    deribit: { equity, available, orders, futurePositions, optionPositions, fundingGains },
    eth: ethInfo,
    priceHistory: historyPrices
  };
}

app.get('/api/data', async (req, res) => {
  try {
    const role = req.session.role || 'readonly';
    if (Date.now() - cache.ts < CACHE_TTL && cache.data) {
      return res.json({ ...cache.data, role });
    }
    const data = await fetchAllData();
    cache = { data, ts: Date.now() };
    res.json({ ...data, role });
  } catch (err) {
    if (cache.data) return res.json({ ...cache.data, role: req.session.role || 'readonly' });
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/close-position', express.json(), async (req, res) => {
  if (req.session.role !== 'admin') return res.status(403).json({ error: 'Accès refusé' });
  try {
    const { instrument } = req.body;
    if (!instrument) return res.status(400).json({ error: 'Missing instrument' });

    const token = await getDeribitToken();
    const posRes = await deribit('private/get_positions', { currency: 'USDC' }, token);
    const pos = (posRes.result || []).find(p => p.instrument_name === instrument && p.size !== 0);
    if (!pos) return res.status(404).json({ error: 'No open position found' });

    const result = await deribit('private/close_position', {
      instrument_name: instrument,
      type: 'market'
    }, token);

    if (result.error) {
      return res.status(500).json({ error: result.error.message || JSON.stringify(result.error) });
    }

    cache = { data: null, ts: 0 };

    const order = result.result?.order;
    const trade = result.result?.trades?.[0];
    res.json({
      ok: true,
      closed: {
        direction: pos.direction,
        size: order?.filled_amount || pos.size_currency || pos.size,
        price: trade?.price || order?.average_price,
        pnl: trade?.profit_loss ?? pos.floating_profit_loss
      }
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/funding-reset', express.json(), (req, res) => {
  if (!req.session?.user) return res.status(401).json({ error: 'Not authenticated' });
  if (req.session.user !== 'xou') return res.status(403).json({ error: 'Admin only' });
  const now = Date.now();
  setFundingReset({ resetTimestamp: now, resetTotal: 0 });
  res.json({ ok: true, resetTimestamp: now });
});

// LSM Status endpoint
app.get('/api/lsm-status', (req, res) => {
  if (!req.session?.user) return res.status(401).json({ error: 'Not authenticated' });
  
  // Mock LSM data
  const lsmData = {
    active: true,
    killed: false,
    botThreshold: 2,
    maxGasPrice: 80,
    minHealthFactor: 1.55,
    dailyTxCount: 0,
    maxDailyTx: 20,
    proposalTTL: 1800,
    lastExecution: null,
    moduleAddress: '0x40f7b06433f27B9C9C24fD5d60F2816F9344e04E',
    network: 'sepolia',
    grafanaUrl: 'https://ratpoison2.duckdns.org/grafana/'
  };
  
  res.json(lsmData);
});

app.listen(PORT, '0.0.0.0', () => console.log('Dashboard running on 0.0.0.0:' + PORT));
