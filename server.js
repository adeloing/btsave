const express = require('express');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const path = require('path');

const session = require('express-session');
const app = express();
const PORT = 3001;

// === AUTH CONFIG ===
const SESSION_SECRET = 'btsave-kei-' + crypto.randomBytes(8).toString('hex');
const USERS = {
  xou: { hash: process.env.DASH_XOU_HASH || crypto.createHash('sha256').update(process.env.DASH_XOU_PWD || 'changeme').digest('hex'), role: 'admin' },
  mael: { hash: process.env.DASH_MAEL_HASH || crypto.createHash('sha256').update(process.env.DASH_MAEL_PWD || 'changeme').digest('hex'), role: 'readonly' }
};

app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, maxAge: 30 * 24 * 3600 * 1000 }
}));

app.use(express.urlencoded({ extended: false }));

// Detect base path from reverse proxy (Caddy strips /dashboard/)
function getBasePath(req) {
  return req.headers['x-forwarded-prefix'] || process.env.BASE_PATH || '';
}

app.post('/auth/login', (req, res) => {
  const { username, password } = req.body;
  const hash = crypto.createHash('sha256').update(password || '').digest('hex');
  const base = getBasePath(req);
  if (USERS[username] && USERS[username].hash === hash) {
    req.session.user = username;
    req.session.role = USERS[username].role;
    res.redirect(base + '/');
  } else {
    res.redirect(base + '/login.html?error=1');
  }
});

app.get('/auth/logout', (req, res) => {
  const base = getBasePath(req);
  req.session.destroy(() => res.redirect(base + '/login.html'));
});

function requireAuth(req, res, next) {
  if (req.path === '/login.html' || req.path.startsWith('/auth/') || req.path === '/logo.svg') return next();
  if (req.session?.user) return next();
  if (req.path.startsWith('/api/')) return res.status(401).json({ error: 'Not authenticated' });
  const base = getBasePath(req);
  res.redirect(base + '/login.html');
}
app.use(requireAuth);

// === Arbitrum On-Chain Config ===
const ARB_RPC = 'https://arb1.arbitrum.io/rpc';
const AAVE_WALLET = '0x5F8E0020C3164fB7EB170D7345672F6948Ca0FF4';
const AAVE_POOL = '0x794a61358D6845594F94dc1DB02A252b5b4814aD';
const WBTC_ARB = '0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f';
const USDC_ARB = '0xaf88d065e77c8cC2239327C5EDb3A432268e5831';

// AAVE V3 Arbitrum aTokens / debt tokens
const AWBTC = '0x078f358208685046a11C85e8ad32895DED33A249'; // aArbWBTC
const AUSDC = '0x724dc807b04555b71ed48a6896b6F41593b8C637'; // aArbUSDC  
const DEBT_USDC = '0xFCCf3cAbbe80101232d343252614b6A3eE81C989'; // variableDebtArbUSDC
// Note: These are the standard Arbitrum AAVE V3 aToken addresses.
// If wallet has no positions on Arbitrum AAVE, values will be 0.

// GMX V2 Arbitrum
const GMX_READER = '0x0000000000000000000000000000000000000000'; // TODO: GMX V2 Reader contract
const GMX_DATASTORE = '0x0000000000000000000000000000000000000000'; // TODO: GMX V2 DataStore

// Aevo Adapter (puts)
const AEVO_ADAPTER = '0x0000000000000000000000000000000000000000'; // TODO: deploy

// Strategy / Vault / DAO (TODO: deploy these)
const STRATEGY_CONTRACT = '0x0000000000000000000000000000000000000000'; // TODO
const VAULT_CONTRACT = '0x0000000000000000000000000000000000000000'; // TODO
const TIMELOCK_CONTROLLER = '0x0000000000000000000000000000000000000000'; // TODO
const NFT_BONUS_CONTRACT = '0x0000000000000000000000000000000000000000'; // TODO

// === Cache ===
let cache = { data: null, ts: 0 };
const CACHE_TTL = 15000;

// === RPC helpers ===
function rpcCall(rpcUrl, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(rpcUrl);
    const mod = url.protocol === 'https:' ? https : http;
    const req = mod.request({
      hostname: url.hostname, path: url.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json' }
    }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch(e) { reject(e); } });
    });
    req.on('error', reject);
    req.write(JSON.stringify(body)); req.end();
  });
}

function ethCall(to, data) {
  return rpcCall(ARB_RPC, { jsonrpc: '2.0', method: 'eth_call', params: [{ to, data }, 'latest'], id: 1 });
}

function ethBatch(calls) {
  const batch = calls.map((c, i) => ({ jsonrpc: '2.0', method: 'eth_call', params: [{ to: c.to, data: c.data }, 'latest'], id: i }));
  return rpcCall(ARB_RPC, batch);
}

function toBig(hex) { return !hex || hex === '0x' || hex === '0x0' ? 0n : BigInt(hex); }

// === AAVE V3 Arbitrum ===
async function fetchAAVE() {
  const addr = AAVE_WALLET.replace('0x', '').toLowerCase();
  const padAddr = '000000000000000000000000' + addr;
  const balOf = '0x70a08231' + padAddr;

  try {
    const results = await ethBatch([
      { to: AAVE_POOL, data: '0xbf92857c' + padAddr }, // getUserAccountData
      { to: AWBTC, data: balOf },
      { to: AUSDC, data: balOf },
      { to: DEBT_USDC, data: balOf },
    ]);

    if (!Array.isArray(results)) {
      // Single response wrapped
      throw new Error('Unexpected RPC response');
    }

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
      usdcCol: Number(toBig(results[2].result)) / 1e6,
      debtUSDC: Number(toBig(results[3].result)) / 1e6,
    };
  } catch (e) {
    console.error('AAVE fetch error:', e.message);
    return null;
  }
}

// === BTC Price via CoinGecko ===
async function fetchBTCPrice() {
  return new Promise((resolve) => {
    https.get('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd', res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => {
        try {
          const r = JSON.parse(d);
          resolve(r.bitcoin?.usd || 0);
        } catch { resolve(0); }
      });
    }).on('error', () => resolve(0));
  });
}

// === GMX V2 Positions (placeholder — needs real Reader contract) ===
async function fetchGMXPositions() {
  // TODO: Implement actual GMX V2 Reader.getPositionInfo() calls
  // GMX V2 Reader contract on Arbitrum reads from DataStore
  // For now return empty/mock data
  return {
    positions: [],
    totalSizeBTC: 0,
    totalCollateralUSD: 0,
    totalPnlUSD: 0,
    totalFundingUSD: 0,
  };
}

// === Aevo Puts (placeholder — needs deployed AevoAdapter) ===
async function fetchAevoPositions() {
  // TODO: Read from deployed AevoAdapter contract
  // AevoAdapter.getPut(1), getPut(2), getPut(3) + totalPutValue()
  // For now return placeholder
  return {
    puts: [], // { palier, strike, collateralUSDC, expiry, currentValueUSDC, active }
    totalValueUSD: 0,
    totalAllocatedUSD: 0,
    activePutCount: 0,
    contractAddress: AEVO_ADAPTER,
  };
}

// === Strategy Phase ===
function getStrategyPhase(gmxPositions, aave) {
  // TODO: Read from strategy contract when deployed
  // For now, derive from positions
  if (!gmxPositions || gmxPositions.positions.length === 0) return 'IDLE';
  // If there are active shorts, we're hedged
  const hasShorts = gmxPositions.positions.some(p => p.isShort);
  if (hasShorts) return 'HEDGED';
  return 'IDLE';
}

// === DAO Info (placeholder) ===
async function fetchDAOInfo() {
  // TODO: Read from deployed contracts
  return {
    timelockAddress: TIMELOCK_CONTROLLER,
    roles: {
      admin: '0x0000000000000000000000000000000000000000', // TODO
      guardian: '0x0000000000000000000000000000000000000000', // TODO
      keeper: '0x0000000000000000000000000000000000000000', // TODO
    },
    nftBonus: {
      totalHolders: 0, // TODO: read from NFTBonus contract
      cyclesCompleted: 0,
      contractAddress: NFT_BONUS_CONTRACT,
    },
    fees: {
      baseEntryFeeBps: 200, // 2% base (5% near ATH)
      athEntryFeeBps: 500,  // 5% when price > 95% ATH
      effectiveFeeBps: 200, // TODO: compute with NFT discount from vault
      nftDiscountPct: 0,
      exitFeeSchedule: [
        { days: '<7', feeBps: 200, label: '2.0%' },
        { days: '7-29', feeBps: 100, label: '1.0%' },
        { days: '30-89', feeBps: 50, label: '0.5%' },
        { days: '≥90', feeBps: 0, label: '0%' },
      ],
      drawdownBonusBps: 100, // +1% if BTC < 90% ATH
    },
    contracts: {
      vault: VAULT_CONTRACT,
      strategy: STRATEGY_CONTRACT,
      timelock: TIMELOCK_CONTROLLER,
      nftBonus: NFT_BONUS_CONTRACT,
      aevoAdapter: AEVO_ADAPTER,
    },
  };
}

// === Arbitrum ETH balance & gas ===
async function fetchArbInfo() {
  try {
    const addr = AAVE_WALLET.toLowerCase();
    const results = await rpcCall(ARB_RPC, [
      { jsonrpc: '2.0', method: 'eth_getBalance', params: [addr, 'latest'], id: 0 },
      { jsonrpc: '2.0', method: 'eth_gasPrice', params: [], id: 1 }
    ]);
    if (!Array.isArray(results)) return null;
    results.sort((a, b) => a.id - b.id);
    const ethBalance = Number(toBig(results[0].result)) / 1e18;
    const gasPriceWei = Number(toBig(results[1].result));
    const gasPriceGwei = gasPriceWei / 1e9;
    return {
      ethBalance: +ethBalance.toFixed(6),
      gasPriceGwei: +gasPriceGwei.toFixed(3),
    };
  } catch (e) {
    console.error('Arb info error:', e.message);
    return null;
  }
}

process.on('uncaughtException', (err) => { console.error('UNCAUGHT:', err.message); });
process.on('unhandledRejection', (err) => { console.error('UNHANDLED:', err.message || err); });

app.use(express.static('public'));

async function fetchAllData() {
  const [btcPrice, aave, gmx, aevo, dao, arbInfo] = await Promise.all([
    fetchBTCPrice(),
    fetchAAVE(),
    fetchGMXPositions(),
    fetchAevoPositions(),
    fetchDAOInfo(),
    fetchArbInfo(),
  ]);

  const price = btcPrice;
  const phase = getStrategyPhase(gmx, aave);

  // NAV computation
  let nav = null;
  if (aave) {
    const netUSD = aave.totalCollateralUSD - aave.totalDebtUSD;
    nav = {
      totalAssetsUSD: +aave.totalCollateralUSD.toFixed(2),
      totalDebtUSD: +aave.totalDebtUSD.toFixed(2),
      netUSD: +netUSD.toFixed(2),
      // TODO: Add vault totalSupply to compute TPB price
      tpbPrice: 0, // TODO: vault.totalAssets() / vault.totalSupply()
    };
  }

  // Health factor zone
  const hf = aave ? aave.healthFactor : 99;
  let currentZone = 'safe';
  if (hf >= 2.0) currentZone = 'safe';
  else if (hf >= 1.5) currentZone = 'monitor';
  else if (hf >= 1.3) currentZone = 'warning';
  else currentZone = 'danger';

  // Operational metrics
  const ath = 0; // TODO: read from strategy.currentATH()
  const drawdownPct = ath > 0 && price > 0 ? ((ath - price) / ath * 100) : 0;
  const inDrawdown = ath > 0 && price < ath * 0.9;

  return {
    price,
    phase,
    currentZone,
    ath,
    drawdownPct: +drawdownPct.toFixed(2),
    inDrawdown,
    aave: aave ? {
      wbtcBTC: +aave.wbtcBTC.toFixed(8),
      usdcCol: +aave.usdcCol.toFixed(2),
      debtUSDC: +aave.debtUSDC.toFixed(2),
      totalCollateralUSD: +aave.totalCollateralUSD.toFixed(2),
      totalDebtUSD: +aave.totalDebtUSD.toFixed(2),
      availableBorrowsUSD: +aave.availableBorrowsUSD.toFixed(2),
      healthFactor: +aave.healthFactor.toFixed(4),
      ltv: aave.ltv,
      liquidationThreshold: aave.liquidationThreshold,
    } : null,
    gmx: {
      positions: gmx.positions,
      totalSizeBTC: gmx.totalSizeBTC,
      totalCollateralUSD: gmx.totalCollateralUSD,
      totalPnlUSD: gmx.totalPnlUSD,
      totalFundingUSD: gmx.totalFundingUSD,
    },
    aevo,
    dao,
    nav,
    arb: arbInfo,
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
    console.error('API error:', err.message);
    if (cache.data) return res.json({ ...cache.data, role: req.session.role || 'readonly' });
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, '0.0.0.0', () => console.log('BTSAVE Dashboard running on 0.0.0.0:' + PORT));
