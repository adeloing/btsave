const express = require('express');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const session = require('express-session');
const app = express();
const PORT = 3001;

// === AUTH CONFIG ===
const SESSION_SECRET = 'btsave-kei-' + crypto.randomBytes(8).toString('hex');
// Password hashed with SHA-256
const USERS = {
  xou: { hash: crypto.createHash('sha256').update('682011sac').digest('hex'), role: 'admin' },
  mael: { hash: crypto.createHash('sha256').update('mael').digest('hex'), role: 'readonly' }
};

app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, maxAge: 30 * 24 * 3600 * 1000 } // 30 days
}));

app.use(express.urlencoded({ extended: false }));

// Auth routes
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

// Auth middleware
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

// === Cache ===
let cache = { data: null, ts: 0 };
const CACHE_TTL = 15000; // 15s

// Deribit token cache (expires_in is typically 900s)
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

// Batch ETH RPC calls
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
      { to: AAVE_POOL, data: '0xbf92857c' + padAddr }, // getUserAccountData
      { to: AWBTC, data: balOf },                        // aWBTC balance
      { to: AUSDT, data: balOf },                        // aUSDT balance
      { to: DEBT_USDT, data: balOf },                    // debt USDT
    ]);

    // Sort by id
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
    };
  } catch (e) {
    console.error('AAVE fetch error:', e.message);
    return null;
  }
}

// Price history — cached separately
let historyCache = { data: null, ts: 0 };
const HISTORY_TTL = 300000; // 5 min for intraday

async function fetchPriceHistory() {
  if (Date.now() - historyCache.ts < HISTORY_TTL && historyCache.data) return historyCache.data;
  const end = Date.now();
  const start = end - 3 * 86400000; // 3 days of hourly candles
  return new Promise((resolve) => {
    const url = `/api/v2/public/get_tradingview_chart_data?instrument_name=BTC_USDC-PERPETUAL&start_timestamp=${start}&end_timestamp=${end}&resolution=60`;
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

// Fetch ETH balance + gas price
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
    // Estimate swap tx cost: ~150k gas
    const swapCostETH = (gasPriceWei * 150000) / 1e18;
    // Fetch ETH price from Deribit
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

  // Parallel: all Deribit calls + AAVE + history + ETH info
  const [ticker, account, ordersRes, posRes, tradesRes, aave, historyPrices, ethInfo] = await Promise.all([
    deribit('public/ticker', { instrument_name: 'BTC_USDC-PERPETUAL' }, token),
    deribit('private/get_account_summary', { currency: 'USDC' }, token),
    deribit('private/get_open_orders_by_currency', { currency: 'USDC' }, token),
    deribit('private/get_positions', { currency: 'USDC' }, token),
    deribit('private/get_user_trades_by_currency', { currency: 'USDC', kind: 'future', count: 100, sorting: 'desc' }, token).catch(() => ({ result: { trades: [] } })),
    fetchAAVE(),
    fetchPriceHistory(),
    fetchEthInfo(),
  ]);

  const price = ticker.result.last_price;
  const equity = account.result.equity;
  const available = account.result.available_funds;

  const orders = (ordersRes.result || []).map(o => ({
    direction: o.direction, price: o.price, amount: o.amount,
    type: o.order_type, label: o.label || '', state: o.order_state,
    trigger: o.trigger_price || null
  }));

  const positions = (posRes.result || []).filter(p => p.size !== 0).map(p => ({
    instrument: p.instrument_name, size: p.size_currency || p.size, direction: p.direction,
    avgPrice: p.average_price, pnl: p.floating_profit_loss, leverage: p.leverage
  }));

  // Strategy state
  const ATH = 126000;
  const PAS = 0.05 * ATH;
  const MAX_STEP_REACHED = 9; // highest step ever crossed (update when new steps fill)
  const halfSpread = PAS / 6; // PAS/3 spread, centered on prix
  const steps = Array.from({length: 19}, (_, i) => {
    const prix = ATH - (i+1) * PAS;
    const lo = Math.round(prix - halfSpread);
    const hi = Math.round(prix + halfSpread);
    return { step: i+1, prix: +prix.toFixed(0), lo, hi };
  });

  let currentStep = 0;
  for (const s of steps) {
    if (price < s.prix) currentStep = s.step;
  }

  // Derive next actions from actual Deribit orders (not theoretical steps)
  const buyOrders = orders.filter(o => o.direction === 'buy').sort((a, b) => (a.trigger || a.price) - (b.trigger || b.price));
  const sellOrders = orders.filter(o => o.direction === 'sell').sort((a, b) => (b.trigger || b.price) - (a.trigger || a.price));
  const nearestBuy = buyOrders[0]; // lowest buy trigger = nearest above
  const nearestSell = sellOrders[0]; // highest sell trigger = nearest below

  // Map back to step info for display
  const nextUp = nearestBuy ? steps.find(s => s.lo === (nearestBuy.trigger || nearestBuy.price) || s.hi === (nearestBuy.trigger || nearestBuy.price)) || { step: '?', prix: nearestBuy.trigger || nearestBuy.price, lo: nearestBuy.trigger || nearestBuy.price } : null;
  const nextDown = nearestSell ? steps.find(s => s.hi === (nearestSell.trigger || nearestSell.price) || s.lo === (nearestSell.trigger || nearestSell.price)) || { step: '?', prix: nearestSell.trigger || nearestSell.price, lo: nearestSell.trigger || nearestSell.price } : null;

  const wbtcBTC = aave ? aave.wbtcBTC : null;
  const debtUSDT = aave ? aave.debtUSDT : null;
  const healthFactor = aave ? aave.healthFactor : null;

  // Total BTC @ ATH breakdown (active conversion strategy)
  const extraBTC = 1.065; // BTC to return to owner at ATH
  let athBreakdown = null;
  if (aave) {
    // On the way up, USDT col is actively converted to BTC at each step
    // This buys 0.9 BTC at avg price ~$94,500
    const p2Btc = currentStep * 0.1; // BTC bought with USDT on the way up
    // USDT debt remains and is repaid by selling BTC at ATH
    const debtRepayBtc = aave.debtUSDT / ATH; // BTC sold to repay USDT debt
    // P1: remaining BTC collateral + P2 bought - debt repay - extra returned
    const p1Btc = wbtcBTC - extraBTC;
    // P2 net: bought 0.9 BTC, sold 0.675 to repay debt = +0.225
    const p2Net = p2Btc - debtRepayBtc;
    const totalBtcATH = p1Btc + p2Net;
    athBreakdown = {
      p1Btc: +p1Btc.toFixed(4),
      p2Btc: +p2Btc.toFixed(4),
      p2Net: +p2Net.toFixed(4),
      debtRepayBtc: +debtRepayBtc.toFixed(4),
      totalBtc: +totalBtcATH.toFixed(4),
      totalUSD: +(totalBtcATH * ATH).toFixed(0),
      extraReturned: extraBTC
    };
  }

  // Grid gains from completed trades
  const trades = (tradesRes.result && tradesRes.result.trades) || [];
  const gridTrades = trades.filter(t => t.label && t.label.startsWith('grid_'));
  let gridGains = { totalPnl: 0, tradeCount: gridTrades.length, trades: [] };
  // Sum profit_loss from all grid trades
  for (const t of gridTrades) {
    gridGains.totalPnl += t.profit_loss || 0;
    gridGains.trades.push({
      direction: t.direction,
      price: t.price,
      amount: t.amount,
      pnl: t.profit_loss || 0,
      label: t.label,
      timestamp: t.timestamp
    });
  }
  gridGains.totalPnl = +gridGains.totalPnl.toFixed(2);

  return {
    price, ATH, PAS, currentStep, maxStepReached: MAX_STEP_REACHED, steps,
    nextDown: nextDown || null,
    nextUp: nextUp || null,
    aave: aave ? {
      wbtcBTC: +wbtcBTC.toFixed(8),
      usdtCol: +aave.usdtCol.toFixed(2),
      debtUSDT: +aave.debtUSDT.toFixed(2),
      totalCollateralUSD: +aave.totalCollateralUSD.toFixed(2),
      totalDebtUSD: +aave.totalDebtUSD.toFixed(2),
      availableBorrowsUSD: +aave.availableBorrowsUSD.toFixed(2),
      healthFactor: +aave.healthFactor.toFixed(4),
      ltv: aave.ltv,
      liquidationThreshold: aave.liquidationThreshold,
      athBreakdown
    } : null,
    deribit: { equity, available, orders, positions, gridGains },
    eth: ethInfo,
    priceHistory: historyPrices
  };
}

app.get('/api/data', async (req, res) => {
  try {
    const role = req.session.role || 'readonly';
    // Serve from cache if fresh
    if (Date.now() - cache.ts < CACHE_TTL && cache.data) {
      return res.json({ ...cache.data, role });
    }
    const data = await fetchAllData();
    cache = { data, ts: Date.now() };
    res.json({ ...data, role });
  } catch (err) {
    // Serve stale cache on error
    if (cache.data) return res.json({ ...cache.data, role: req.session.role || 'readonly' });
    res.status(500).json({ error: err.message });
  }
});

// Close position endpoint (admin only)
app.post('/api/close-position', express.json(), async (req, res) => {
  if (req.session.role !== 'admin') return res.status(403).json({ error: 'Accès refusé' });
  try {
    const { instrument } = req.body;
    if (!instrument) return res.status(400).json({ error: 'Missing instrument' });

    const token = await getDeribitToken();

    // Get current position to determine direction
    const posRes = await deribit('private/get_positions', { currency: 'USDC' }, token);
    const pos = (posRes.result || []).find(p => p.instrument_name === instrument && p.size !== 0);
    if (!pos) return res.status(404).json({ error: 'No open position found' });

    // Use close_position API — closes entire position by instrument
    const result = await deribit('private/close_position', {
      instrument_name: instrument,
      type: 'market'
    }, token);

    console.log('close_position result:', JSON.stringify(result));

    if (result.error) {
      return res.status(500).json({ error: result.error.message || JSON.stringify(result.error) });
    }

    // Invalidate cache
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

app.listen(PORT, '0.0.0.0', () => console.log('Dashboard running on 0.0.0.0:' + PORT));
