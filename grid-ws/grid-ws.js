#!/usr/bin/env node
// Deribit Grid WebSocket Monitor — Sliding Window
// Real-time order fill detection via WebSocket subscription.

const WebSocket = require('ws');
const https = require('https');
const fs = require('fs');

// === CONFIG ===
const CLIENT_ID = 'hvWM-oCG';
const CLIENT_SECRET = 'FRkOz3Zqo0LCIKnyxTfUZ15aWgZLbmTJid9k4ATU720';
const INSTRUMENT = 'BTC_USDC-PERPETUAL';
const ORDER_SIZE = 0.1;
const ATH = 126000;
const PAS = 6300;
const STATE_FILE = '/home/xou/.openclaw/workspace/memory/deribit-grid-state.json';
const NOTIFY_FILE = '/home/xou/deribit-grid-ws/notifications.jsonl';
const WS_URL = 'wss://www.deribit.com/ws/api/v2';
const RECONNECT_DELAY = 10000;
const PING_INTERVAL = 25000;

// === GRID MATH ===
function stepLevel(n) {
  const prix = ATH - n * PAS;
  const buy = Math.floor(prix / 1000) * 1000;
  return { buy, sell: buy + 1000 };
}

// === GLOBALS ===
let state = null;
let ws = null;
let token = null;
let pingTimer = null;
let msgIdCounter = 1;
let pendingCallbacks = new Map(); // id -> callback
let handling = false; // prevent concurrent fill handling

function log(...args) {
  console.log(`[${new Date().toISOString()}]`, ...args);
}

// === STATE ===
function loadState() {
  state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  log('State loaded:', state.activeOrders.length, 'active orders');
}

function saveState() {
  state.lastCheck = Date.now();
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// === NOTIFICATION ===
function notify(msg) {
  log('NOTIFY:', msg);
  fs.appendFileSync(NOTIFY_FILE, JSON.stringify({ ts: new Date().toISOString(), msg }) + '\n');
  try {
    const { execSync } = require('child_process');
    execSync(`openclaw message send --channel whatsapp --to "+33669621894" --message ${JSON.stringify(msg)}`, {
      timeout: 15000, stdio: 'pipe'
    });
    log('WhatsApp sent');
  } catch (e) {
    log('WhatsApp failed:', e.message?.slice(0, 100));
  }
}

// === DERIBIT REST (for order placement/cancellation) ===
function deribitRest(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params });
    const req = https.request({
      hostname: 'www.deribit.com', path: '/api/v2/' + method, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token }
    }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => {
        try {
          const p = JSON.parse(d);
          if (p.error) reject(new Error(JSON.stringify(p.error)));
          else resolve(p.result);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

async function placeOrder(direction, price, label, currentPrice) {
  // For SELL above current price or BUY below current price: use limit
  // For SELL below current price or BUY above current price: use stop_limit
  const useLimit = (direction === 'sell' && price > currentPrice) || (direction === 'buy' && price < currentPrice);
  const orderType = useLimit ? 'limit' : 'stop_limit';
  
  log(`Place ${direction} ${orderType} @ ${price} [${label}] (spot: ${currentPrice})`);
  
  const params = {
    instrument_name: INSTRUMENT, amount: ORDER_SIZE,
    type: orderType, price: price,
    time_in_force: 'good_til_cancelled', label
  };
  
  if (orderType === 'stop_limit') {
    params.trigger_price = price;
    params.trigger = 'last_price';
  } else {
    params.post_only = true;
  }
  
  const result = await deribitRest(`private/${direction}`, params);
  log(`Placed: ${result.order.order_id} (${orderType})`);
  return result.order;
}

async function cancelOrder(orderId) {
  log(`Cancel ${orderId}`);
  await deribitRest('private/cancel', { order_id: orderId });
  log(`Cancelled ${orderId}`);
}

// === SLIDING WINDOW ===
async function handleFill(filledOrder) {
  if (handling) { log('Already handling a fill, skipping'); return; }
  handling = true;

  try {
    const { step, direction, trigger, order_id } = filledOrder;
    log(`=== FILL === ${direction} step ${step} @ ${trigger}`);
    notify(`⚡ FILL: ${direction.toUpperCase()} 0.1 BTC @ $${trigger} (step ${step})`);

    // Remove from active
    state.activeOrders = state.activeOrders.filter(o => o.order_id !== order_id);
    if (!state.filledOrders) state.filledOrders = [];
    state.filledOrders.push({ ...filledOrder, filledAt: new Date().toISOString() });

    // Get current price for order type selection
    const ticker = await deribitRest('public/ticker', { instrument_name: INSTRUMENT });
    const currentPrice = ticker.last_price;
    log(`Current price: ${currentPrice}`);

    if (direction === 'buy') {
      // Price went UP past step N buy_level
      // Add: BUY at step (N-1), SELL at step N's sell_level
      // Cancel: furthest SELL (lowest trigger)
      const newBuyStep = step - 1;
      if (newBuyStep >= 1) {
        const lvl = stepLevel(newBuyStep).buy;
        const o = await placeOrder('buy', lvl, `grid_step${newBuyStep}_up`, currentPrice);
        state.activeOrders.push({ label: `grid_step${newBuyStep}_up`, direction: 'buy', trigger: lvl, step: newBuyStep, order_id: o.order_id });
      } else {
        notify('⚠️ At step 1 — no buy above');
      }

      const sellLvl = stepLevel(step).sell;
      const so = await placeOrder('sell', sellLvl, `grid_step${step}_down`, currentPrice);
      state.activeOrders.push({ label: `grid_step${step}_down`, direction: 'sell', trigger: sellLvl, step, order_id: so.order_id });

      // Cancel furthest sell
      const sells = state.activeOrders.filter(o => o.direction === 'sell').sort((a, b) => a.trigger - b.trigger);
      if (sells.length > 2) {
        await cancelOrder(sells[0].order_id);
        state.activeOrders = state.activeOrders.filter(o => o.order_id !== sells[0].order_id);
      }

    } else {
      // Price went DOWN past step N sell_level
      // Add: SELL at step (N+1), BUY at step N's buy_level
      // Cancel: furthest BUY (highest trigger)
      const newSellStep = step + 1;
      if (newSellStep <= 19) {
        const lvl = stepLevel(newSellStep).sell;
        const o = await placeOrder('sell', lvl, `grid_step${newSellStep}_down`, currentPrice);
        state.activeOrders.push({ label: `grid_step${newSellStep}_down`, direction: 'sell', trigger: lvl, step: newSellStep, order_id: o.order_id });
      } else {
        notify('⚠️ At step 19 — no sell below');
      }

      const buyLvl = stepLevel(step).buy;
      const bo = await placeOrder('buy', buyLvl, `grid_step${step}_up`, currentPrice);
      state.activeOrders.push({ label: `grid_step${step}_up`, direction: 'buy', trigger: buyLvl, step, order_id: bo.order_id });

      // Cancel furthest buy
      const buys = state.activeOrders.filter(o => o.direction === 'buy').sort((a, b) => b.trigger - a.trigger);
      if (buys.length > 2) {
        await cancelOrder(buys[0].order_id);
        state.activeOrders = state.activeOrders.filter(o => o.order_id !== buys[0].order_id);
      }
    }

    // Verify 2+2
    const buys = state.activeOrders.filter(o => o.direction === 'buy');
    const sells = state.activeOrders.filter(o => o.direction === 'sell');
    if (buys.length !== 2 || sells.length !== 2) {
      notify(`⚠️ Imbalance: ${buys.length} BUY + ${sells.length} SELL — check needed!`);
    } else {
      const bl = buys.map(o => o.trigger).sort((a,b) => b-a).join('/');
      const sl = sells.map(o => o.trigger).sort((a,b) => b-a).join('/');
      notify(`✅ Grid repositioned: BUY ${bl} | SELL ${sl}`);
    }
    saveState();
  } catch (e) {
    log('ERROR handleFill:', e.message);
    notify(`🚨 Grid error: ${e.message} — manual check needed!`);
    saveState();
  } finally {
    handling = false;
  }
}

// === WEBSOCKET ===
function nextId() { return msgIdCounter++; }

function wsSend(method, params = {}) {
  const id = nextId();
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  }
  return id;
}

function wsSendWithCallback(method, params, cb) {
  const id = nextId();
  pendingCallbacks.set(id, cb);
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  }
  // Timeout cleanup
  setTimeout(() => pendingCallbacks.delete(id), 30000);
  return id;
}

function startPing() {
  if (pingTimer) clearInterval(pingTimer);
  pingTimer = setInterval(() => wsSend('public/test'), PING_INTERVAL);
}

function stopPing() {
  if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
}

function connect() {
  log('Connecting...');
  ws = new WebSocket(WS_URL);

  ws.on('open', () => {
    log('Connected, authenticating...');
    wsSendWithCallback('public/auth', {
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET
    }, (result) => {
      token = result.access_token;
      log(`Authenticated (expires ${result.expires_in}s)`);
      
      // Subscribe to order updates
      wsSendWithCallback('private/subscribe', {
        channels: [`user.orders.${INSTRUMENT}.raw`]
      }, () => {
        log('Subscribed to order updates ✓');
        startPing();
      });
    });
  });

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    // Response to a request we made
    if (msg.id && pendingCallbacks.has(msg.id)) {
      const cb = pendingCallbacks.get(msg.id);
      pendingCallbacks.delete(msg.id);
      if (msg.result) cb(msg.result);
      else if (msg.error) log('RPC error:', JSON.stringify(msg.error));
      return;
    }

    // Subscription push
    if (msg.method === 'subscription' && msg.params?.channel?.startsWith('user.orders.')) {
      const orders = Array.isArray(msg.params.data) ? msg.params.data : [msg.params.data];
      for (const order of orders) {
        log(`Order update: ${order.order_id} state=${order.order_state} label=${order.label}`);
        if (order.order_state === 'filled') {
          const stateOrder = state.activeOrders.find(o => o.order_id === order.order_id);
          if (stateOrder) {
            handleFill(stateOrder).catch(e => log('Fill error:', e));
          }
        }
      }
      return;
    }

    // heartbeat from Deribit
    if (msg.method === 'heartbeat') {
      if (msg.params?.type === 'test_request') {
        wsSend('public/test');
      }
      return;
    }
  });

  ws.on('close', (code, reason) => {
    log(`Disconnected: ${code} ${reason}`);
    stopPing();
    pendingCallbacks.clear();
    setTimeout(connect, RECONNECT_DELAY);
  });

  ws.on('error', (err) => log('WS error:', err.message));
}

// === MAIN ===
log('=== Deribit Grid WS Monitor v2 ===');
loadState();
connect();

process.on('SIGTERM', () => { log('Shutting down...'); stopPing(); ws?.close(); process.exit(0); });
process.on('SIGINT', () => { log('Shutting down...'); stopPing(); ws?.close(); process.exit(0); });
