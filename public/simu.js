// §HELPERS
const fmt = n => n.toLocaleString('fr-FR');
const fmtUSD = n => n < 0 ? '−$' + fmt(Math.abs(Math.round(n))) : '$' + fmt(Math.round(n));
const fmtBTC = (n, d=4) => n.toFixed(d) + ' BTC';
const $ = id => document.getElementById(id);

// §STATE - Hybrid ZERO-LIQ Strategy
let CFG = {}, stepPrices = [];
let prevStep = 0, maxStep = 0;
let firstCrossed = {};
let deribitPos = {};       // step -> { entry } — active shorts
let deribitRealizedPnL = 0;
let deribitFees = 0;       // accumulated trading fees
let deribitWithdrawn = 0;  // cumulative USDC transferred Deribit → AAVE
let notionalSum = 0;       // sum of open notional at each crossing (for contango calc)
const DERIBIT_FEE = 0.0005; // 0.05% taker (stop orders)
let crossings = 0, roundTrips = 0;
let log = [], savedConfigHTML = '';

// Management zones thresholds (%)
const ZONE1_THRESHOLD = -12.3;  // -12.3%
const ZONE2_THRESHOLD = -17.6;  // -17.6% 
const STOP_THRESHOLD = -21.0;   // -21%
const EMERGENCY_THRESHOLD = -26.0; // -26%

// Puts tracking
let putsPortfolio = { bought: 0, cost: 0, sold: 0, pnl: 0 }; // tracks puts positions

// §INIT
document.addEventListener('DOMContentLoaded', () => {
  // Auto-update calculated fields
  const updateCalcs = () => {
    const ath = +$('cfg-ath').value || 126000;
    const wbtcStart = +$('cfg-wbtc-start').value || 3.90;
    
    // Buffer USDC AAVE = 18%
    $('cfg-buffer-pct').value = '18';
    
    // Marge Deribit = 3%  
    $('cfg-deribit-pct').value = '3';
  };
  
  updateCalcs();
  $('cfg-ath').addEventListener('input', updateCalcs);
  $('cfg-wbtc-start').addEventListener('input', updateCalcs);
});

// §MANAGEMENT-ZONES
function getManagementZone(price, ath) {
  const pct = ((price - ath) / ath) * 100;
  
  if (pct <= EMERGENCY_THRESHOLD) return 'emergency';
  if (pct <= STOP_THRESHOLD) return 'stop';
  if (pct <= ZONE2_THRESHOLD) return 'zone2';
  if (pct <= ZONE1_THRESHOLD) return 'zone1';
  return 'accumulation';
}

function getZoneColor(zone) {
  const colors = {
    accumulation: '#6ee7a0',   // green
    zone1: '#f6b06b',          // orange
    zone2: '#f87171',          // red
    stop: '#ef4444',           // dark red
    emergency: '#dc2626'       // very dark red
  };
  return colors[zone] || '#6ee7a0';
}

function getZoneLabel(zone) {
  const labels = {
    accumulation: 'ACCUMULATION',
    zone1: 'ZONE 1 (-12.3%)',
    zone2: 'ZONE 2 (-17.6%)', 
    stop: 'STOP (-21%)',
    emergency: 'EMERGENCY (-26%)'
  };
  return labels[zone] || 'ACCUMULATION';
}

// §LAUNCH
function launch() {
  const ath = +$('cfg-ath').value;
  const wbtcStart = +$('cfg-wbtc-start').value;
  const existingDebt = +$('cfg-existing-debt').value;
  const contango = +$('cfg-contango').value;
  const cycleDays = +$('cfg-cycle-days').value;
  const putCostPctYear = +$('cfg-put-cost').value;

  CFG = {
    ATH: ath,
    wbtcStart: wbtcStart,
    stepSize: ath * 0.05,
    borrowPerStep: Math.round(wbtcStart * 3200 / 100) * 100, // rounded to nearest 100
    shortPerStep: +(wbtcStart * 0.0244).toFixed(3),
    bufferUSDC: wbtcStart * ath * 0.18,
    deribitTarget: wbtcStart * ath * 0.03,
    contango: contango,
    cycleDays: cycleDays,
    putCostPctYear: putCostPctYear,
    existingDebt: existingDebt
  };

  // Generate step prices (ATH down to -95%)
  stepPrices = [CFG.ATH];
  for (let i = 1; i <= 19; i++) {
    stepPrices[i] = CFG.ATH - i * CFG.stepSize;
  }

  prevStep = 0; maxStep = 0; firstCrossed = {};
  deribitPos = {}; deribitRealizedPnL = 0; deribitFees = 0; deribitWithdrawn = 0; notionalSum = 0;
  roundTrips = 0; crossings = 0; log = [];
  putsPortfolio = { bought: 0, cost: 0, sold: 0, pnl: 0 };
  $('action-log').innerHTML = '';
  $('log-section').style.display = 'none';

  savedConfigHTML = $('phase-config').innerHTML;

  // Grid table — step prices and accumulation amounts
  let rows = stepPrices.map((p, i) => {
    if (i === 0) {
      return `<tr style="border-bottom:1px solid var(--border)"><td class="tc b" style="color:var(--accent)">ATH</td><td class="tc b">${fmtUSD(p)}</td><td class="tc muted">—</td><td class="tc muted">—</td></tr>`;
    }
    
    const zone = getManagementZone(p, CFG.ATH);
    const zoneColor = getZoneColor(zone);
    const zoneStyle = zone !== 'accumulation' ? `style="color:${zoneColor}"` : '';
    
    return `<tr style="border-bottom:1px solid var(--border)" id="sr-${i}"><td class="tc b">${i}</td><td class="tc b">${fmtUSD(p)}</td><td class="tc">${fmtBTC(CFG.shortPerStep)}</td><td class="tc" ${zoneStyle}>${getZoneLabel(zone)}</td></tr>`;
  }).join('');

  $('phase-config').innerHTML = `
    <div class="section">
      <h3>📐 Grille Hybrid ZERO-LIQ Strategy</h3>
      <div style="overflow-x:auto">
        <table style="width:100%;border-collapse:collapse;font-size:11px">
          <thead>
            <tr style="color:var(--muted);text-transform:uppercase;font-size:9px;letter-spacing:0.5px">
              <th class="tc">Step</th><th class="tc">Trigger</th><th class="tc">Short BTC</th><th class="tc">Zone</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
      <div style="margin-top:10px;font-size:11px;color:var(--muted)">
        <div><strong>Formules:</strong></div>
        <div>• step_size = ${fmtUSD(CFG.stepSize)} (ATH × 5%)</div>
        <div>• borrow_per_step = ${fmtUSD(CFG.borrowPerStep)} (${fmtBTC(CFG.wbtcStart)} × 3200)</div>
        <div>• short_per_step = ${fmtBTC(CFG.shortPerStep)} (${fmtBTC(CFG.wbtcStart)} × 0.0244)</div>
      </div>
    </div>`;

  $('phase-sim').style.display = '';
  $('header-price').style.display = '';
  $('header-stats').style.display = '';
  $('hdr-ath').textContent = fmtUSD(CFG.ATH);
  $('hdr-pas').textContent = fmtUSD(CFG.stepSize);
  
  const pi = $('price-input');
  pi.value = CFG.ATH;
  pi.addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
  
  sim(CFG.ATH);
}

// §RESET
function resetSim() {
  $('phase-config').innerHTML = savedConfigHTML;
  $('phase-sim').style.display = 'none';
  $('header-price').style.display = 'none';
  $('header-stats').style.display = 'none';
  $('badge-step').textContent = 'CONFIG';
  $('badge-step').style.background = '';
  $('sim-dashboard').innerHTML = '';
  $('action-log').innerHTML = '';
  $('log-section').style.display = 'none';
  const pi = $('price-input');
  if (pi) { pi.disabled = false; pi.style.opacity = ''; }
  
  prevStep = 0; maxStep = 0; firstCrossed = {};
  deribitPos = {}; deribitRealizedPnL = 0; deribitFees = 0; deribitWithdrawn = 0; notionalSum = 0;
  roundTrips = 0; crossings = 0; log = [];
  putsPortfolio = { bought: 0, cost: 0, sold: 0, pnl: 0 };
}

function go() { const v = +$('price-input').value; if (v > 0) sim(v); }

// §CALC — compute full state for a given step position
function calcState(price, cur) {
  // Current zone
  const currentZone = getManagementZone(price, CFG.ATH);
  
  // ═══ WBTC Collateral (79% initially + accumulated) ═══
  let accumulatedBtc = 0;
  for (let i = 1; i <= maxStep; i++) {
    if (firstCrossed[i]) {
      accumulatedBtc += CFG.shortPerStep; // We bought shortPerStep BTC at each first crossing
    }
  }
  const totalWbtc = CFG.wbtcStart + accumulatedBtc;

  // ═══ USDC AAVE (18% buffer + transfers from Deribit) ═══
  const usdcAave = CFG.bufferUSDC + deribitWithdrawn;

  // ═══ Debt Calculation ═══
  let p2Debt = 0;
  for (let i = 1; i <= maxStep; i++) {
    if (firstCrossed[i]) {
      p2Debt += CFG.borrowPerStep; // Fixed borrow amount per step
    }
  }
  const totalDebt = CFG.existingDebt + p2Debt;

  // ═══ Deribit: active shorts ═══
  let deribitUnrealized = 0, shortCount = 0, deribitNotional = 0;
  for (const [step, pos] of Object.entries(deribitPos)) {
    const stepPrice = stepPrices[step];
    const pnl = CFG.shortPerStep * (pos.entry - price);
    deribitUnrealized += pnl;
    deribitNotional += CFG.shortPerStep * price;
    shortCount++;
  }

  const deribitTotal = deribitUnrealized + deribitRealizedPnL;
  const deribitEquity = CFG.deribitTarget + deribitTotal - deribitWithdrawn;
  const deribitIM = deribitNotional * 0.05; // 5% initial margin

  // Transfers logic
  const deribitKeep = Math.max(CFG.deribitTarget * 0.5, deribitIM * 2);
  const transferable = Math.max(0, deribitEquity - deribitKeep);
  const needsTopup = Math.max(0, deribitIM * 1.5 - deribitEquity);

  // ═══ AAVE Health Calculation (78% liquidation threshold) ═══
  const totalCollateralUSD = (totalWbtc * price) + usdcAave;
  const hf = totalDebt > 0 ? (totalCollateralUSD * 0.78) / totalDebt : 99;
  const ltv = totalCollateralUSD > 0 ? totalDebt / totalCollateralUSD * 100 : 0;
  const liqPrice = totalWbtc > 0 ? (totalDebt / 0.78 - usdcAave) / totalWbtc : 0;
  const aaveNet = totalCollateralUSD - totalDebt;

  // ═══ Portfolio Total ═══
  const portfolio = totalCollateralUSD - totalDebt + deribitEquity;

  // ═══ Contango Calculation ═══
  const contangoYear = deribitNotional * CFG.contango / 100;
  const contangoMonth = contangoYear / 12;

  // ═══ Puts Cost Estimation ═══
  const putsCostYear = totalWbtc * price * CFG.putCostPctYear / 100; // Cost to hedge accumulated BTC

  return {
    currentZone,
    totalWbtc, usdcAave, accumulatedBtc, p2Debt, totalDebt, 
    totalCollateralUSD, hf, ltv, liqPrice, aaveNet,
    shortCount, deribitNotional, deribitUnrealized, deribitTotal, deribitEquity,
    deribitIM, deribitKeep, transferable, needsTopup, deribitWithdrawn,
    contangoYear, contangoMonth, putsCostYear, portfolio
  };
}

// §LOG-RENDER
function renderLog() {
  if (!log.length) return;
  $('log-section').style.display = '';
  $('action-log').innerHTML = log.map(e => {
    const arrow = e.dir === 'down' ? '📉' : '📈';
    const dirColor = e.dir === 'down' ? 'var(--red)' : 'var(--green)';

    const actionsHTML = e.actions.map(a => {
      const icon = a.dir === 'down' ? '🔻' : '🔺';
      const mClass = a.mode === 'auto' ? 'auto' : 'manuel';
      let stepsHTML = '';
      if (a.steps && a.steps.length) {
        stepsHTML = `<div style="margin-top:6px;padding:6px 8px;background:rgba(255,255,255,0.03);border-radius:6px;font-size:11px">
          ${a.steps.map((s, idx) => {
            if (s.section) {
              return `<div style="display:flex;align-items:center;gap:6px;padding:6px 0 2px;${idx > 0 ? 'margin-top:4px;border-top:1px solid rgba(255,255,255,0.06)' : ''}">
                <span style="font-size:12px">${s.icon}</span>
                <span style="font-weight:800;font-size:10px;text-transform:uppercase;letter-spacing:0.5px;color:${s.highlight || 'var(--muted)'}">${s.text}</span>
              </div>`;
            }
            const badgeHTML = s.badge ? `<span class="action-mode ${s.badge}" style="font-size:8px;padding:1px 5px;flex-shrink:0">${s.badge.toUpperCase()}</span>` : '';
            return `<div style="display:flex;align-items:center;gap:8px;padding:3px 0 3px 20px">
              <span style="min-width:20px;text-align:center;font-size:11px">${s.icon}</span>
              ${badgeHTML}
              <span style="${s.highlight ? 'font-weight:700;color:' + s.highlight : ''}">${s.text}</span>
            </div>`;
          }).join('')}
        </div>`;
      }
      return `<div style="padding:6px 0;border-bottom:1px solid rgba(255,255,255,0.03)">
        <div style="display:flex;align-items:center;gap:8px">
          <span style="font-size:14px">${icon}</span>
          <div style="flex:1">
            <div style="display:flex;align-items:center;gap:6px;margin-bottom:2px">
              <span style="font-weight:700;font-size:13px">Step ${a.step}</span>
              <span style="font-size:11px;color:var(--muted)">@ ${fmtUSD(a.triggerPrice)}</span>
              <span class="action-mode ${mClass}">${a.mode.toUpperCase()}</span>
            </div>
            <div style="font-size:11px;color:var(--muted)">${a.desc}</div>
          </div>
        </div>
        ${stepsHTML}
      </div>`;
    }).join('');

    return `<div class="log-entry">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid var(--border)">
        <div style="display:flex;align-items:center;gap:8px">
          <span style="font-size:18px">${arrow}</span>
          <div>
            <div style="font-size:15px;font-weight:800;color:${dirColor}">${fmtUSD(e.price)}</div>
            <div style="font-size:10px;color:var(--muted)">Step ${e.from} → ${e.to}</div>
          </div>
        </div>
        <div style="text-align:right">
          <div style="font-size:13px;font-weight:700">HF ${e.snap.hf}</div>
          <div style="font-size:10px;color:var(--muted)">Portfolio ${e.snap.portfolio}</div>
        </div>
      </div>
      <div style="margin-bottom:6px">${actionsHTML}</div>
    </div>`;
  }).join('');
}

// §SIMULATE
function sim(price) {
  // §END-CHECK: price above ATH = cycle terminé
  if (price > CFG.ATH && maxStep >= 1) {
    let actions = [];
    
    // Close all shorts
    if (prevStep > 0) {
      crossings += prevStep;
      for (let i = prevStep; i > 0; i--) {
        const entry = deribitPos[i] ? deribitPos[i].entry : stepPrices[i];
        const fee = CFG.shortPerStep * price * DERIBIT_FEE;
        const pnl = CFG.shortPerStep * (entry - price) - fee;
        deribitFees += fee;
        deribitRealizedPnL += pnl;
        delete deribitPos[i];
        actions.push({ dir: 'up', step: i, triggerPrice: price, mode: 'auto',
          desc: `Fermer SHORT ${fmtBTC(CFG.shortPerStep)} au nouvel ATH`,
          steps: [
            { icon: '📊', text: `Deribit: BUY ${fmtBTC(CFG.shortPerStep)} @ ${fmtUSD(price)}` },
            { icon: '💸', text: `Fee: −${fmtUSD(fee)}`, highlight: 'var(--red)' },
          ] });
      }
    }

    // Calculate final BTC after cycle completion
    const S = calcState(CFG.ATH, 0);
    const finalBtc = S.totalWbtc;

    $('hdr-price').textContent = fmtUSD(price);
    $('hdr-pct').textContent = '+' + ((price - CFG.ATH) / CFG.ATH * 100).toFixed(1) + '%';
    $('hdr-steps').textContent = crossings;
    $('badge-step').textContent = '✅ NOUVEAU ATH';
    $('badge-step').style.background = 'linear-gradient(135deg, #6ee7a0, #4ade80)';
    $('price-input').disabled = true;
    $('price-input').style.opacity = '0.4';

    $('sim-dashboard').innerHTML = `
      <div class="section" style="text-align:center;border:1px solid rgba(110,231,160,0.3);background:rgba(110,231,160,0.05)">
        <h3 style="color:var(--green);margin-bottom:12px">🏁 Cycle terminé — Nouveau ATH</h3>
        <div style="font-size:11px;color:var(--muted)">Palier max : Step ${maxStep} | ${crossings} paliers franchis | Accumulation terminée</div>
      </div>

      <div class="section" style="text-align:center">
        <h3>Nouveau collatéral BTC total</h3>
        <div style="font-size:28px;font-weight:800;color:var(--green);margin:8px 0">${fmtBTC(finalBtc)}</div>
        <div style="font-size:14px;color:var(--muted)">${fmtUSD(finalBtc * CFG.ATH)}</div>
        <div style="margin-top:12px;display:flex;justify-content:center;gap:16px;font-size:12px;flex-wrap:wrap">
          <span>Initial: ${fmtBTC(CFG.wbtcStart)}</span>
          <span class="green">Accumulé: +${fmtBTC(S.accumulatedBtc)}</span>
        </div>
      </div>

      <div class="section">
        <h3>📊 Actions de reset</h3>
        <div style="font-size:11px;line-height:1.6">
          <div>✅ Fermer tous les shorts Deribit</div>
          <div>✅ Rembourser 100% de la dette AAVE</div>
          <div>✅ Conserver tout WBTC accumulé</div>
          <div>⚠️ Rééquilibrer en 79% WBTC / 18% USDC AAVE / 3% USDC Deribit</div>
        </div>
      </div>`;

    renderLog();
    prevStep = 0;
    return;
  }

  // §STEP-DETECTION — triggers aux prix des steps
  let cur = 0;
  for (let i = 1; i <= 19; i++) if (price <= stepPrices[i]) cur = i;
  if (cur > maxStep) maxStep = cur;

  // §STEP-CHANGES — actions selon la zone de gestion
  let actions = [];
  const currentZone = getManagementZone(price, CFG.ATH);

  if (prevStep !== null && cur !== prevStep) {
    crossings += Math.abs(cur - prevStep);

    if (cur > prevStep) {
      // ═══ GOING DOWN ═══
      for (let i = prevStep + 1; i <= cur; i++) {
        const triggerPrice = stepPrices[i];
        const zone = getManagementZone(triggerPrice, CFG.ATH);
        const notional = CFG.shortPerStep * triggerPrice;
        const fee = notional * DERIBIT_FEE;
        const marginReq = notional * 0.05;
        deribitFees += fee;
        deribitRealizedPnL -= fee;

        // Check if we should stop borrowing (stop/emergency zones)
        const shouldBorrow = zone === 'accumulation' || zone === 'zone1' || zone === 'zone2';

        if (!firstCrossed[i]) {
          firstCrossed[i] = true;
          deribitPos[i] = { entry: triggerPrice };
          
          let steps = [
            { icon: '📊', text: `DERIBIT`, highlight: 'var(--accent)', section: true },
            { icon: '⚡', text: `SELL STOP ${fmtBTC(CFG.shortPerStep)} @ ${fmtUSD(triggerPrice)}`, badge: 'auto' },
            { icon: '💸', text: `Fee: −${fmtUSD(fee)} (0.05%)`, highlight: 'var(--red)' }
          ];

          if (shouldBorrow) {
            steps.push(
              { icon: '🏦', text: `AAVE`, highlight: 'var(--accent)', section: true },
              { icon: '📝', text: `Emprunter ${fmtUSD(CFG.borrowPerStep)} USDC`, badge: 'manuel' },
              { icon: '📝', text: `DeFiLlama: ${fmtUSD(CFG.borrowPerStep)} USDC → ${fmtBTC(CFG.shortPerStep)} aEthWBTC`, badge: 'manuel' }
            );
          } else {
            steps.push(
              { icon: '🏦', text: `AAVE — STOP: pas d'emprunt en zone ${getZoneLabel(zone)}`, section: true, highlight: 'var(--red)' }
            );
          }

          // Zone-specific management actions
          if (zone === 'zone1') {
            steps.push(
              { icon: '🎯', text: `ZONE 1`, highlight: 'var(--orange)', section: true },
              { icon: '📝', text: `Vendre 50% des puts → rembourser 25% dette`, badge: 'manuel', highlight: 'var(--orange)' }
            );
          } else if (zone === 'zone2') {
            steps.push(
              { icon: '🎯', text: `ZONE 2`, highlight: 'var(--red)', section: true },
              { icon: '📝', text: `Vendre puts restants → rembourser 40% dette restante`, badge: 'manuel', highlight: 'var(--red)' }
            );
          } else if (zone === 'emergency') {
            steps.push(
              { icon: '🚨', text: `EMERGENCY`, highlight: '#dc2626', section: true },
              { icon: '📝', text: `Vendre tous puts + rembourser maximum de dette`, badge: 'manuel', highlight: '#dc2626' }
            );
          }

          actions.push({
            dir: 'down', step: i, triggerPrice, mode: shouldBorrow ? 'manuel' : 'auto',
            desc: `${getZoneLabel(zone)} — 1ère traversée`,
            steps
          });
        } else {
          // Re-traversée (round trip)
          roundTrips++;
          deribitPos[i] = { entry: triggerPrice };
          actions.push({
            dir: 'down', step: i, triggerPrice, mode: 'auto',
            desc: `Re-traversée automatique (${getZoneLabel(zone)})`,
            steps: [
              { icon: '📊', text: `DERIBIT`, highlight: 'var(--accent)', section: true },
              { icon: '⚡', text: `SELL STOP ${fmtBTC(CFG.shortPerStep)} @ ${fmtUSD(triggerPrice)}`, badge: 'auto' },
              { icon: '💸', text: `Fee: −${fmtUSD(fee)}`, highlight: 'var(--red)' },
              { icon: '🏦', text: `AAVE — Aucune action`, section: true }
            ]
          });
        }
      }
    } else {
      // ═══ GOING UP ═══
      for (let i = prevStep; i > cur; i--) {
        const entry = deribitPos[i] ? deribitPos[i].entry : stepPrices[i];
        const exitPrice = stepPrices[i];
        const fee = CFG.shortPerStep * exitPrice * DERIBIT_FEE;
        const pnl = CFG.shortPerStep * (entry - exitPrice) - fee;
        deribitFees += fee;
        deribitRealizedPnL += pnl;
        delete deribitPos[i];

        actions.push({
          dir: 'up', step: i, triggerPrice: exitPrice, mode: 'auto',
          desc: `Fermer short automatiquement`,
          steps: [
            { icon: '📊', text: `BUY STOP ${fmtBTC(CFG.shortPerStep)} @ ${fmtUSD(exitPrice)}`, badge: 'auto' },
            { icon: '💸', text: `Fee: −${fmtUSD(fee)}`, highlight: 'var(--red)' },
            { icon: '💰', text: `PnL: ${fmtUSD(pnl)}`, highlight: pnl >= 0 ? 'var(--green)' : 'var(--red)' }
          ]
        });
      }
    }

    // Handle transfers after position changes
    const Stx = calcState(price, cur);
    if (actions.length && Stx.transferable > 100) {
      const last = actions[actions.length - 1];
      const txAmount = Stx.transferable;
      deribitWithdrawn += txAmount;
      last.steps.push(
        { icon: '🔄', text: `TRANSFERT`, highlight: 'var(--accent)', section: true },
        { icon: '📊', text: `Transférer ${fmtUSD(txAmount)} USDC Deribit → AAVE`, badge: 'manuel', highlight: 'var(--green)' }
      );
    }
  }

  // §NOTIONAL-TRACKING
  if (actions.length) {
    let openNotional = 0;
    for (const [s, pos] of Object.entries(deribitPos)) {
      openNotional += CFG.shortPerStep * pos.entry;
    }
    notionalSum += openNotional;
  }

  // §STATE-CALC
  const S = calcState(price, cur);
  const pct = ((price - CFG.ATH) / CFG.ATH * 100).toFixed(1);

  // §HEADER
  $('hdr-price').textContent = fmtUSD(price);
  $('hdr-pct').textContent = pct + '%';
  $('hdr-steps').textContent = crossings;
  
  const zoneColor = getZoneColor(S.currentZone);
  $('badge-step').textContent = cur === 0 ? 'ATH' : `Step ${cur}/19 (${getZoneLabel(S.currentZone)})`;
  $('badge-step').style.background = cur === 0 ? '' : `linear-gradient(135deg, ${zoneColor}, ${zoneColor}aa)`;

  // Highlight current step in grid
  for (let i = 1; i <= 19; i++) {
    const r = $('sr-' + i);
    if (r) r.style.background = i === cur ? 'rgba(246,176,107,0.15)' : '';
  }

  const hfC = S.hf < 1.5 ? 'red' : S.hf < 2.0 ? 'orange' : 'green';
  const hfBg = { green: 'rgba(110,231,160,0.18)', orange: 'rgba(246,176,107,0.25)', red: 'rgba(248,113,113,0.25)' }[hfC];

  // §RENDER
  $('sim-dashboard').innerHTML = `
    <div class="section" style="text-align:center;padding:12px">
      <div class="card-label">Portfolio total</div>
      <div style="font-size:26px;font-weight:800;margin:6px 0;color:var(--green)">${fmtUSD(S.portfolio)}</div>
      <div style="font-size:11px;color:var(--muted)">AAVE net: ${fmtUSD(S.aaveNet)} · Deribit: ${fmtUSD(S.deribitEquity)}</div>
    </div>

    <div class="section" style="text-align:center;padding:8px 12px;background:rgba(${S.currentZone === 'accumulation' ? '110,231,160' : S.currentZone === 'zone1' ? '246,176,107' : '248,113,113'},0.1);border:1px solid rgba(${S.currentZone === 'accumulation' ? '110,231,160' : S.currentZone === 'zone1' ? '246,176,107' : '248,113,113'},0.3)">
      <div style="font-size:14px;font-weight:700;color:${zoneColor}">${getZoneLabel(S.currentZone)}</div>
      <div style="font-size:10px;color:var(--muted);margin-top:2px">Zone de gestion active</div>
    </div>

    <div class="section" style="padding:0;overflow:hidden">
      <div class="aave-hf-bar" style="background:${hfBg}">
        <span>🏦 AAVE V3 — Health Factor</span>
        <span>${S.hf.toFixed(2)}</span>
      </div>
      <div style="padding:12px">
        <div style="display:flex;gap:12px">
          <div class="aave-col">
            <div class="card-label" style="margin-bottom:8px;color:var(--green)">✦ ACTIF</div>
            <div class="aave-row"><span class="aave-row-icon">₿</span><span class="aave-row-val">${fmtBTC(S.totalWbtc)}</span></div>
            <div style="font-size:9px;color:var(--muted);margin:-4px 0 4px 24px">Initial: ${fmtBTC(CFG.wbtcStart)} · Accumulé: +${fmtBTC(S.accumulatedBtc)}</div>
            ${S.usdcAave > CFG.bufferUSDC ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(S.usdcAave)} <span class="card-sub">USDC</span></span></div>
            <div style="font-size:9px;color:var(--muted);margin:-4px 0 4px 24px">Buffer: ${fmtUSD(CFG.bufferUSDC)} · Deribit→AAVE: +${fmtUSD(S.deribitWithdrawn)}</div>` : 
            `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(CFG.bufferUSDC)} <span class="card-sub">USDC buffer</span></span></div>`}
            <div style="flex:1"></div>
            <div class="aave-total"><div class="card-sub">Total</div><div style="font-weight:700">${fmtUSD(S.totalCollateralUSD)}</div></div>
          </div>
          <div class="divider-v"></div>
          <div class="aave-col">
            <div class="card-label" style="margin-bottom:8px;color:var(--red)">✦ PASSIF</div>
            ${CFG.existingDebt > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(CFG.existingDebt)} <span class="card-sub">Dette existante</span></span></div>` : ''}
            ${S.p2Debt > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(S.p2Debt)} <span class="card-sub">Dette accumulation</span></span></div>` : ''}
            ${S.totalDebt === 0 ? `<div class="aave-row"><span class="aave-row-icon">✅</span><span class="aave-row-val" style="color:var(--green)">Aucune dette</span></div>` : ''}
            <div style="flex:1"></div>
            <div class="aave-total"><div class="card-sub">Total</div><div style="font-weight:700;color:var(--red)">${fmtUSD(S.totalDebt)}</div></div>
          </div>
        </div>
        <div class="aave-footer">
          <span>LTV: ${S.ltv.toFixed(1)}%</span><span>Net: ${fmtUSD(S.aaveNet)}</span><span class="orange">Liq: ${fmtUSD(S.liqPrice)}</span>
        </div>
      </div>
    </div>

    <div class="section" style="padding:0;overflow:hidden">
      <div style="padding:8px 12px;background:rgba(96,165,250,0.12);display:flex;justify-content:space-between;align-items:center;font-size:13px;font-weight:700">
        <span>📊 Deribit — Futures Hedge</span>
        <span>${S.shortCount} short${S.shortCount !== 1 ? 's' : ''} · ${fmtBTC(S.shortCount * CFG.shortPerStep)}</span>
      </div>
      <div style="padding:12px">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;font-size:12px">
          <div style="padding:6px;text-align:center;background:var(--bg);border-radius:6px">
            <div class="card-label">PnL non réalisé</div>
            <div style="font-weight:700;margin-top:2px;color:${S.deribitUnrealized >= 0 ? 'var(--green)' : 'var(--red)'}">${fmtUSD(S.deribitUnrealized)}</div>
          </div>
          <div style="padding:6px;text-align:center;background:var(--bg);border-radius:6px">
            <div class="card-label">PnL réalisé</div>
            <div style="font-weight:700;margin-top:2px;color:${deribitRealizedPnL >= 0 ? 'var(--green)' : 'var(--red)'}">${fmtUSD(deribitRealizedPnL)}</div>
          </div>
          <div style="padding:6px;text-align:center;background:var(--bg);border-radius:6px">
            <div class="card-label">Équité</div>
            <div style="font-weight:700;margin-top:2px">${fmtUSD(S.deribitEquity)}</div>
          </div>
          <div style="padding:6px;text-align:center;background:var(--bg);border-radius:6px">
            <div class="card-label">Contango annuel</div>
            <div style="font-weight:700;margin-top:2px;color:var(--green)">${fmtUSD(S.contangoYear)}</div>
          </div>
        </div>
        ${S.transferable > 100 ? `<div style="margin-top:8px;padding:6px;background:rgba(110,231,160,0.1);border-radius:6px;font-size:11px;color:var(--green);text-align:center;font-weight:700">📊→🏦 ${fmtUSD(S.transferable)} USDC transférables vers AAVE</div>` : ''}
      </div>
    </div>

    ${S.putsCostYear > 0 ? `<div class="section" style="text-align:center">
      <h3>🛡️ Protection Puts OTM (${CFG.putCostPctYear}%/an)</h3>
      <div class="card-value orange">${fmtUSD(S.putsCostYear)}/an</div>
      <div class="card-sub">Protection sur ${fmtBTC(S.totalWbtc)} accumulé</div>
    </div>` : ''}

    <div class="section">
      <h3>📊 Répartition Live (79/18/3)</h3>
      <div style="font-size:11px;line-height:1.8">
        <div style="display:flex;justify-content:space-between;">
          <span>🪙 WBTC AAVE:</span>
          <span><strong>${fmtUSD(S.totalWbtc * price)}</strong> (${((S.totalWbtc * price) / S.totalCollateralUSD * 100).toFixed(1)}%)</span>
        </div>
        <div style="display:flex;justify-content:space-between;">
          <span>💵 USDC AAVE:</span>
          <span><strong>${fmtUSD(S.usdcAave)}</strong> (${(S.usdcAave / S.totalCollateralUSD * 100).toFixed(1)}%)</span>
        </div>
        <div style="display:flex;justify-content:space-between;">
          <span>📊 USDC Deribit:</span>
          <span><strong>${fmtUSD(S.deribitEquity)}</strong> (${(S.deribitEquity / S.totalCollateralUSD * 100).toFixed(1)}%)</span>
        </div>
      </div>
    </div>

    ${actions.length ? `<div class="section" style="border:1px solid var(--accent);background:rgba(246,176,107,0.05)">
      <h3 style="color:var(--accent)">⚖️ Actions requises</h3>
      ${actions.map(a => {
        const dirIcon = a.dir === 'down' ? '▼' : '▲';
        const dirColor = a.dir === 'down' ? 'var(--red)' : 'var(--green)';
        const mClass = a.mode === 'auto' ? 'auto' : 'manuel';
        return '<div style="margin-bottom:10px;padding:10px;background:var(--bg);border-radius:8px;border-left:3px solid ' + dirColor + '">' +
          '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">' +
          '<span style="font-weight:800;font-size:13px;color:' + dirColor + '">' + dirIcon + ' Step ' + a.step + '</span>' +
          '<span style="font-size:11px;color:var(--muted)">@ ' + fmtUSD(a.triggerPrice) + '</span>' +
          '<span class="action-mode ' + mClass + '" style="margin-left:auto">' + a.mode.toUpperCase() + '</span></div>' +
          '<div style="font-size:11px;color:var(--muted);margin-bottom:6px">' + a.desc + '</div>' +
          (a.steps || []).map(s => {
            if (s.section) {
              return '<div style="display:flex;align-items:center;gap:6px;padding:5px 0 2px;margin-top:3px;border-top:1px solid rgba(255,255,255,0.05)">' +
                '<span style="font-size:11px">' + s.icon + '</span>' +
                '<span style="font-weight:800;font-size:9px;text-transform:uppercase;letter-spacing:0.5px;color:' + (s.highlight || 'var(--muted)') + '">' + s.text + '</span></div>';
            }
            const badge = s.badge ? '<span class="action-mode ' + s.badge + '" style="font-size:8px;padding:1px 5px">' + s.badge.toUpperCase() + '</span>' : '';
            return '<div style="display:flex;align-items:center;gap:8px;padding:3px 0 3px 16px">' +
              '<span style="font-size:11px;min-width:20px;text-align:center">' + s.icon + '</span>' +
              badge +
              '<span style="font-size:11px;' + (s.highlight ? 'font-weight:700;color:' + s.highlight : '') + '">' + s.text + '</span></div>';
          }).join('') +
          '</div>';
      }).join('')}
    </div>` : ''}`;

  // §LOG
  if (actions.length) {
    const dir = cur > prevStep ? 'down' : 'up';
    log.unshift({ price, from: prevStep, to: cur, dir, actions,
      snap: { hf: S.hf.toFixed(2), portfolio: fmtUSD(S.portfolio) } });
    renderLog();
  }
  prevStep = cur;
}