// §HELPERS
const fmt = n => n.toLocaleString('fr-FR');
const fmtUSD = n => n < 0 ? '−$' + fmt(Math.abs(Math.round(n))) : '$' + fmt(Math.round(n));
const fmtBTC = (n, d=4) => n.toFixed(d) + ' BTC';
const $ = id => document.getElementById(id);

// §STATE
let CFG = {}, PAS = 0, stepPrices = [];
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

// §INIT
function updateBtcStep() {
  const w = +$('cfg-wbtc').value || 0;
  $('cfg-btc-step').value = (0.05 * w).toFixed(4);
}
document.addEventListener('DOMContentLoaded', () => {
  updateBtcStep();
  $('cfg-wbtc').addEventListener('input', updateBtcStep);
});

// §LAUNCH
function launch() {
  CFG = {
    ATH: +$('cfg-ath').value, wbtc: +$('cfg-wbtc').value,
    usdtCol: +$('cfg-usdt-col').value, debtUSDT: +$('cfg-debt-usdt').value,
    debtUSDC: +$('cfg-debt-usdc').value, liqPct: +$('cfg-liq').value,
    bps: 0.05 * (+$('cfg-wbtc').value), ret: +$('cfg-btc-return').value,
    deribitMargin: +($('cfg-deribit-margin')?.value || 5000),
    contango: +($('cfg-contango')?.value || 10),
    cycleDays: +($('cfg-cycle-days')?.value || 180),
  };
  PAS = 0.05 * CFG.ATH;
  stepPrices = [CFG.ATH];
  for (let i = 1; i <= 19; i++) stepPrices[i] = CFG.ATH - i * PAS;

  prevStep = 0; maxStep = 0; firstCrossed = {};
  deribitPos = {}; deribitRealizedPnL = 0; deribitFees = 0; deribitWithdrawn = 0; notionalSum = 0;
  roundTrips = 0; crossings = 0; log = [];
  $('action-log').innerHTML = '';
  $('log-section').style.display = 'none';

  savedConfigHTML = $('phase-config').innerHTML;

  // Grid table — ordres aux prix des steps (pas de bornes)
  let rows = stepPrices.map((p, i) => i === 0
    ? `<tr style="border-bottom:1px solid var(--border)"><td class="tc b" style="color:var(--accent)">ATH</td><td class="tc b">${fmtUSD(p)}</td><td class="tc muted">—</td></tr>`
    : `<tr style="border-bottom:1px solid var(--border)" id="sr-${i}"><td class="tc b">${i}</td><td class="tc b">${fmtUSD(p)}</td><td class="tc">${fmtUSD(Math.round(CFG.bps * p))}</td></tr>`
  ).join('');
  $('phase-config').innerHTML = `<div class="section"><h3>📐 Grille Deribit</h3><div style="overflow-x:auto"><table style="width:100%;border-collapse:collapse;font-size:11px"><thead><tr style="color:var(--muted);text-transform:uppercase;font-size:9px;letter-spacing:0.5px"><th class="tc">Step</th><th class="tc">Trigger</th><th class="tc">Montant</th></tr></thead><tbody>${rows}</tbody></table></div></div>`;

  $('phase-sim').style.display = '';
  $('header-price').style.display = '';
  $('header-stats').style.display = '';
  $('hdr-ath').textContent = fmtUSD(CFG.ATH);
  $('hdr-pas').textContent = fmtUSD(PAS);
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
}

function go() { const v = +$('price-input').value; if (v > 0) sim(v); }

// §CALC — compute full state for a given step position
function calcState(price, cur) {
  // ═══ P1: BTC reste sur AAVE, shorts sur Deribit ═══
  const p1Btc = CFG.wbtc; // CONSTANT — jamais swappé

  // ═══ P2: accumulation (premières traversées uniquement) ═══
  let p2Debt = 0;
  for (let i = 1; i <= maxStep; i++) p2Debt += CFG.bps * stepPrices[i];
  const p2Btc = maxStep * CFG.bps;

  // ═══ Deribit: shorts actifs ═══
  let deribitUnrealized = 0, shortCount = 0, shortBtc = 0, deribitNotional = 0;
  for (const [step, pos] of Object.entries(deribitPos)) {
    deribitUnrealized += CFG.bps * (pos.entry - price);
    deribitNotional += CFG.bps * price;
    shortBtc += CFG.bps;
    shortCount++;
  }
  const deribitTotal = deribitUnrealized + deribitRealizedPnL;
  const deribitEquity = CFG.deribitMargin + deribitTotal - deribitWithdrawn;
  const deribitIM = deribitNotional * 0.05;

  // Transfert: gains Deribit → AAVE
  const deribitKeep = Math.max(CFG.deribitMargin * 0.5, deribitIM * 2);
  const transferable = Math.max(0, deribitEquity - deribitKeep);
  const needsTopup = Math.max(0, deribitIM * 1.5 - deribitEquity);

  // ═══ AAVE (avec transferts cumulés) ═══
  const btcCol = p1Btc + p2Btc;
  const usdcOnAave = CFG.usdtCol + deribitWithdrawn;
  const totalDebtUSDT = CFG.debtUSDT + p2Debt;
  const totalDebt = totalDebtUSDT + CFG.debtUSDC;
  const colUSD = btcCol * price + usdcOnAave;
  const hf = totalDebt > 0 ? (colUSD * CFG.liqPct / 100) / totalDebt : 99;
  const ltv = colUSD > 0 ? totalDebt / colUSD * 100 : 0;
  const liq = btcCol > 0 ? (totalDebt / (CFG.liqPct / 100) - usdcOnAave) / btcCol : 0;
  const aaveNet = colUSD - totalDebt;
  const colUSDnoTransfer = btcCol * price + CFG.usdtCol;
  const hfNoTransfer = totalDebt > 0 ? (colUSDnoTransfer * CFG.liqPct / 100) / totalDebt : 99;

  // ═══ Contango ═══
  const contangoYear = deribitNotional * CFG.contango / 100;
  const contangoMonth = contangoYear / 12;

  // ═══ Portfolio total (transferts s'annulent) ═══
  const portfolio = (btcCol * price + CFG.usdtCol) - totalDebt + CFG.deribitMargin + deribitTotal;

  return {
    p1Btc, p2Btc, p2Debt, btcCol, usdcOnAave, totalDebt, colUSD,
    hf, hfNoTransfer, ltv, liq, aaveNet,
    shortCount, shortBtc, deribitNotional, deribitUnrealized, deribitTotal,
    deribitEquity, deribitIM, deribitKeep, transferable, needsTopup,
    deribitWithdrawn,
    contangoYear, contangoMonth, portfolio
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
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px 12px;font-size:10px;color:var(--muted);padding-top:6px;border-top:1px solid var(--border)">
        <span>AAVE Col: <strong style="color:var(--text)">${e.snap.col}</strong></span>
        <span>AAVE Dette: <strong style="color:var(--red)">${e.snap.debt}</strong></span>
        <span>Deribit: <strong style="color:var(--text)">${e.snap.deribit}</strong></span>
        <span class="green">Contango: <strong>${e.snap.contango}/an</strong></span>
      </div>
    </div>`;
  }).join('');
}

// §SIMULATE
function sim(price) {
  // §END-CHECK: price above ATH = cycle terminé
  if (price > CFG.ATH && maxStep >= 1) {
    let actions = [];
    if (prevStep > 0) {
      crossings += prevStep;
      for (let i = prevStep; i > 0; i--) {
        const entry = deribitPos[i] ? deribitPos[i].entry : stepPrices[i];
        const exitPrice = stepPrices[i]; // BUY STOP se déclenche au step price
        const fee = CFG.bps * exitPrice * DERIBIT_FEE;
        const pnl = CFG.bps * (entry - exitPrice) - fee;
        deribitFees += fee;
        deribitRealizedPnL += pnl;
        delete deribitPos[i];
        actions.push({ dir: 'up', step: i, triggerPrice: stepPrices[i], mode: 'auto',
          desc: `Fermer SHORT ${fmtBTC(CFG.bps)} @ ${fmtUSD(exitPrice)} (BUY STOP)`,
          steps: [
            { icon: '📊', text: `Deribit: BUY STOP ${fmtBTC(CFG.bps)} @ ${fmtUSD(exitPrice)} — fermer short step ${i}` },
            { icon: '💸', text: `Fee: −${fmtUSD(fee)}`, highlight: 'var(--red)' },
          ] });
      }
    }

    // P2 settlement @ ATH
    let p2Debt = 0;
    for (let i = 1; i <= maxStep; i++) p2Debt += CFG.bps * stepPrices[i];
    const p2Btc = maxStep * CFG.bps;
    const p2Revenue = p2Btc * CFG.ATH;
    const p2Profit = p2Revenue - p2Debt;
    const p2ProfitBtc = p2Profit / CFG.ATH;

    // Contango earned over cycle
    // Average notional per crossing × contango rate × cycle days
    const avgNotional = crossings > 0 ? notionalSum / crossings : 0;
    const contangoEarned = avgNotional * (CFG.contango / 100) * (CFG.cycleDays / 365);

    // Deribit equity → BTC (fees deducted, contango added, withdrawals subtracted)
    const deribitEquityATH = CFG.deribitMargin + deribitRealizedPnL + contangoEarned - deribitWithdrawn;
    const deribitBtc = deribitEquityATH / CFG.ATH;
    // USDC already on AAVE from transfers
    const usdcOnAaveBtc = deribitWithdrawn / CFG.ATH;

    // Final BTC = P1 + P2 profit + USDC on AAVE + Deribit equity remaining (all in BTC)
    const finalBtc = CFG.wbtc + p2ProfitBtc + usdcOnAaveBtc + deribitBtc - CFG.ret;

    const retUSD = CFG.ret * CFG.ATH;
    const pnlColor = finalBtc >= CFG.wbtc ? 'green' : 'red';

    if (actions.length) {
      const S = calcState(CFG.ATH, 0);
      log.unshift({ price: CFG.ATH, from: prevStep, to: 0, dir: 'up', actions,
        snap: { hf: S.hf.toFixed(2), col: fmtUSD(S.colUSD), debt: fmtUSD(S.totalDebt),
                deribit: fmtUSD(deribitEquityATH), contango: fmtUSD(S.contangoYear), portfolio: fmtUSD(S.portfolio) } });
    }

    $('hdr-price').textContent = fmtUSD(price);
    $('hdr-pct').textContent = '+' + ((price - CFG.ATH) / CFG.ATH * 100).toFixed(1) + '%';
    $('hdr-steps').textContent = crossings;
    $('badge-step').textContent = '✅ TERMINÉ';
    $('badge-step').style.background = 'linear-gradient(135deg, #6ee7a0, #4ade80)';
    $('price-input').disabled = true;
    $('price-input').style.opacity = '0.4';

    $('sim-dashboard').innerHTML = `
      <div class="section" style="text-align:center;border:1px solid rgba(110,231,160,0.3);background:rgba(110,231,160,0.05)">
        <h3 style="color:var(--green);margin-bottom:12px">🏁 Cycle terminé — Nouveau ATH</h3>
        <div style="font-size:11px;color:var(--muted)">Palier max : Step ${maxStep} (${fmtUSD(stepPrices[maxStep])}) | ${crossings} paliers franchis | ${roundTrips} RT</div>
      </div>

      <div class="section" style="text-align:center">
        <h3>Nouveau collatéral BTC</h3>
        <div style="font-size:28px;font-weight:800;color:var(--green);margin:8px 0">${fmtBTC(finalBtc)}</div>
        <div style="font-size:14px;color:var(--muted)">${fmtUSD(finalBtc * CFG.ATH)}</div>
        <div style="margin-top:12px;display:flex;justify-content:center;gap:16px;font-size:12px;flex-wrap:wrap">
          <span>P1: ${fmtBTC(CFG.wbtc)}</span>
          <span class="green">P2: +${fmtBTC(p2ProfitBtc)}</span>
          ${usdcOnAaveBtc > 0.0001 ? `<span class="green">USDC: +${fmtBTC(usdcOnAaveBtc)}</span>` : ''}
          <span class="${deribitBtc >= 0 ? 'green' : 'red'}">Deribit: ${deribitBtc >= 0 ? '+' : ''}${fmtBTC(deribitBtc)}</span>
          ${CFG.ret > 0 ? `<span class="red">−${fmtBTC(CFG.ret)}</span>` : ''}
        </div>
      </div>

      <div class="section">
        <h3>📊 Détail en USD</h3>
        <table style="width:100%;border-collapse:collapse;font-size:13px">
          <tbody>
            <tr style="border-bottom:1px solid var(--border)">
              <td style="padding:8px 0">P2 Accumulation</td>
              <td style="padding:8px 0;text-align:right;font-weight:700;color:var(--green)">+${fmtUSD(p2Profit)}</td>
            </tr>
            <tr style="border-bottom:1px solid var(--border)">
              <td style="padding:8px 0;color:var(--muted);font-size:11px;padding-left:12px">↳ ${fmtBTC(p2Btc)} acheté sous ATH, vendu @ ${fmtUSD(CFG.ATH)}</td>
              <td></td>
            </tr>
            <tr style="border-bottom:1px solid var(--border)">
              <td style="padding:8px 0">Frais Deribit (0.05% taker)</td>
              <td style="padding:8px 0;text-align:right;font-weight:700;color:var(--red)">−${fmtUSD(deribitFees)}</td>
            </tr>
            <tr style="border-bottom:1px solid var(--border)">
              <td style="padding:8px 0">Contango (${CFG.contango}%/an × ${CFG.cycleDays}j)</td>
              <td style="padding:8px 0;text-align:right;font-weight:700;color:var(--green)">+${fmtUSD(contangoEarned)}</td>
            </tr>
            <tr style="border-bottom:1px solid var(--border)">
              <td style="padding:8px 0;color:var(--muted);font-size:11px;padding-left:12px">↳ Net Deribit: ${fmtUSD(deribitRealizedPnL + contangoEarned)} (frais + contango)</td>
              <td></td>
            </tr>
            ${CFG.ret > 0 ? `<tr style="border-bottom:1px solid var(--border)">
              <td style="padding:8px 0">Remboursement BTC</td>
              <td style="padding:8px 0;text-align:right;color:var(--red)">−${fmtUSD(retUSD)}</td>
            </tr>` : ''}
          </tbody>
        </table>
      </div>`;

    renderLog();
    prevStep = 0;
    return;
  }

  // §STEP-DETECTION — triggers aux prix des steps
  let cur = 0;
  for (let i = 1; i <= 19; i++) if (price <= stepPrices[i]) cur = i;
  if (cur > maxStep) maxStep = cur;

  // §STEP-CHANGES — actions par plateforme avec transferts
  let actions = [];
  let transferInfo = null; // calculated after all position changes

  if (prevStep !== null && cur !== prevStep) {
    crossings += Math.abs(cur - prevStep);

    if (cur > prevStep) {
      // ═══ GOING DOWN ═══
      for (let i = prevStep + 1; i <= cur; i++) {
        const notional = CFG.bps * stepPrices[i];
        const fee = notional * DERIBIT_FEE;
        const marginReq = notional * 0.05;
        deribitFees += fee;
        deribitRealizedPnL -= fee;

        if (!firstCrossed[i]) {
          firstCrossed[i] = true;
          deribitPos[i] = { entry: stepPrices[i] };
          actions.push({ dir: 'down', step: i, triggerPrice: stepPrices[i], mode: 'manuel',
            desc: `1ère traversée — hedge + accumulation`,
            steps: [
              { icon: '📊', text: `DERIBIT`, highlight: 'var(--accent)', section: true },
              { icon: '⚡', text: `SELL STOP ${fmtBTC(CFG.bps)} filled @ ${fmtUSD(stepPrices[i])} — short ouvert`, badge: 'auto' },
              { icon: '💸', text: `Fee: −${fmtUSD(fee)} (0.05% taker)`, highlight: 'var(--red)' },
              { icon: '📊', text: `Marge initiale: +${fmtUSD(marginReq)} (5% de ${fmtUSD(notional)})` },
              { icon: '🏦', text: `AAVE`, highlight: 'var(--accent)', section: true },
              { icon: '📝', text: `Emprunter ${fmtUSD(Math.round(notional))} USDT (dette P2)`, badge: 'manuel' },
              { icon: '📝', text: `Acheter ${fmtBTC(CFG.bps)} via DEX`, badge: 'manuel' },
              { icon: '📝', text: `Déposer ${fmtBTC(CFG.bps)} en collatéral`, badge: 'manuel' },
              { icon: '🔄', text: `TRANSFERT`, highlight: 'var(--accent)', section: true },
              { icon: '✅', text: `Aucun — opérations indépendantes sur chaque plateforme` },
            ] });
        } else {
          roundTrips++;
          deribitPos[i] = { entry: stepPrices[i] };
          actions.push({ dir: 'down', step: i, triggerPrice: stepPrices[i], mode: 'auto',
            desc: `Re-traversée — 100% automatique`,
            steps: [
              { icon: '📊', text: `DERIBIT`, highlight: 'var(--accent)', section: true },
              { icon: '⚡', text: `SELL STOP ${fmtBTC(CFG.bps)} filled @ ${fmtUSD(stepPrices[i])} — short ré-ouvert`, badge: 'auto' },
              { icon: '💸', text: `Fee: −${fmtUSD(fee)} (0.05% taker)`, highlight: 'var(--red)' },
              { icon: '📊', text: `Marge requise: +${fmtUSD(marginReq)}` },
              { icon: '🏦', text: `AAVE — Aucune action`, section: true },
              { icon: '🔄', text: `TRANSFERT — Aucun`, section: true },
            ] });
        }
      }
    } else {
      // ═══ GOING UP ═══
      for (let i = prevStep; i > cur; i--) {
        const entry = deribitPos[i] ? deribitPos[i].entry : stepPrices[i];
        const exitPrice = stepPrices[i];
        const fee = CFG.bps * exitPrice * DERIBIT_FEE;
        const marginFreed = CFG.bps * exitPrice * 0.05;
        const pnl = CFG.bps * (entry - exitPrice) - fee;
        deribitFees += fee;
        deribitRealizedPnL += pnl;
        delete deribitPos[i];

        actions.push({ dir: 'up', step: i, triggerPrice: stepPrices[i], mode: 'auto',
          desc: `Fermer short step ${i} — 100% automatique`,
          steps: [
            { icon: '📊', text: `DERIBIT`, highlight: 'var(--accent)', section: true },
            { icon: '⚡', text: `BUY STOP ${fmtBTC(CFG.bps)} filled @ ${fmtUSD(exitPrice)} — short fermé`, badge: 'auto' },
            { icon: '💸', text: `Fee: −${fmtUSD(fee)} (0.05% taker)`, highlight: 'var(--red)' },
            { icon: '📊', text: `Marge libérée: +${fmtUSD(marginFreed)}` },
            { icon: '🏦', text: `AAVE — Aucune action`, section: true },
          ] });
      }
    }

    // === TRANSFER — execute cumulative Deribit → AAVE ===
    const Stx = calcState(price, cur);
    if (Stx.transferable > 100) {
      // Transfer excess to AAVE as USDC collateral
      const txAmount = Stx.transferable;
      deribitWithdrawn += txAmount;
      transferInfo = { dir: 'deribit-to-aave', amount: txAmount,
        text: `📊→🏦 Transférer ${fmtUSD(txAmount)} USDC Deribit → AAVE (collatéral)`,
        sub: `Total transféré: ${fmtUSD(deribitWithdrawn)}`,
        color: 'var(--green)', badge: 'manuel' };
    } else if (Stx.needsTopup > 100) {
      transferInfo = { dir: 'aave-to-deribit', amount: Stx.needsTopup,
        text: `🏦→📊 Envoyer ~${fmtUSD(Stx.needsTopup)} USDC AAVE → Deribit (marge)`,
        color: 'var(--red)', badge: 'manuel' };
    } else {
      transferInfo = { dir: 'none',
        text: `✅ Aucun transfert nécessaire`,
        color: 'var(--muted)' };
    }

    // Append transfer section to last action
    if (actions.length) {
      const last = actions[actions.length - 1];
      last.steps.push({ icon: '🔄', text: `TRANSFERT INTER-PLATEFORMES`, highlight: 'var(--accent)', section: true });
      last.steps.push({ icon: transferInfo.dir === 'none' ? '✅' : '⚠️', text: transferInfo.text,
        highlight: transferInfo.color, badge: transferInfo.badge });
      if (transferInfo.sub) {
        last.steps.push({ icon: '📋', text: transferInfo.sub });
      }
    }
  }

  // §NOTIONAL-TRACKING — for contango calculation
  if (actions.length) {
    let openNotional = 0;
    for (const [s, pos] of Object.entries(deribitPos)) openNotional += CFG.bps * pos.entry;
    notionalSum += openNotional;
  }

  // §STATE-CALC
  const S = calcState(price, cur);
  const pct = ((price - CFG.ATH) / CFG.ATH * 100).toFixed(1);

  // §ATH-PROJECTION — tout réalisé en BTC
  let p2DebtATH = 0;
  for (let i = 1; i <= maxStep; i++) p2DebtATH += CFG.bps * stepPrices[i];
  const p2BtcATH = maxStep * CFG.bps;
  const p2Profit = p2BtcATH * CFG.ATH - p2DebtATH;
  // Deribit: realized + shorts closed at step prices - withdrawals
  let deribitPnLAtATH = deribitRealizedPnL;
  for (const [step, pos] of Object.entries(deribitPos)) {
    deribitPnLAtATH += CFG.bps * (pos.entry - stepPrices[step]);
  }
  const deribitEquityATHproj = CFG.deribitMargin + deribitPnLAtATH - deribitWithdrawn;
  const totalBtcATH = CFG.wbtc + p2Profit / CFG.ATH + deribitWithdrawn / CFG.ATH + deribitEquityATHproj / CFG.ATH - CFG.ret;

  const hfC = S.hf < 1.5 ? 'red' : S.hf < 2.0 ? 'orange' : 'green';
  const hfBg = { green: 'rgba(110,231,160,0.18)', orange: 'rgba(246,176,107,0.25)', red: 'rgba(248,113,113,0.25)' }[hfC];

  // §NEXT-ACTIONS — detailed breakdown per upcoming trigger
  const naRow = (icon, badge, text) => {
    const bHTML = badge ? `<span class="action-mode ${badge}" style="font-size:9px;padding:1px 6px;flex-shrink:0">${badge.toUpperCase()}</span>` : '';
    return `<div style="display:flex;align-items:center;gap:8px;padding:3px 0;font-size:11px">${icon ? `<span style="min-width:22px;text-align:center;font-size:12px">${icon}</span>` : ''}${bHTML}<span style="flex:1">${text}</span></div>`;
  };

  let nextHTML = '';

  // UP triggers: closing shorts — trigger at stepPrices[step] (price rises above it)
  for (let i = cur, n = 0; i >= 1 && n < 2; i--, n++) {
    const trigger = stepPrices[i];
    const amt = CFG.bps;
    const marginFreed = amt * trigger * 0.05;
    let rows = naRow('📊', 'auto', `BUY STOP ${fmtBTC(amt)} @ ${fmtUSD(trigger)} — fermer short step ${i}`);
    rows += naRow('💰', '', `PnL short ≈ $0 (+contango sur quarterly)`);
    rows += naRow('📊', '', `Marge libérée: ~${fmtUSD(marginFreed)}`);
    // Estimate transfer after closing
    const postShorts = S.shortCount - (n + 1);
    if (postShorts === 0 && S.deribitEquity > CFG.deribitMargin * 0.5) {
      rows += naRow('🔄', '', `<strong style="color:var(--green)">📊→🏦 Excédent Deribit transférable vers AAVE</strong>`);
    } else {
      rows += naRow('✅', '', `Aucune action manuelle`);
    }
    nextHTML += `<div style="margin-bottom:10px;padding:10px 12px;background:var(--bg);border-radius:8px;border-left:3px solid var(--green)">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;flex-wrap:wrap">
        <span style="font-size:15px">📈</span>
        <span style="font-weight:700;color:var(--green)">HAUSSE</span>
        <span style="font-weight:700">Step ${i}${i === 1 ? ' → ATH' : ` → ${i - 1}`}</span>
        <span style="color:var(--muted);font-size:12px">trigger @ ${fmtUSD(trigger)}</span>
        <span class="action-mode auto" style="margin-left:auto">AUTO</span>
      </div>
      <div>${rows}</div>
    </div>`;
  }

  // DOWN triggers: opening shorts — trigger at stepPrices[step]
  for (let i = cur + 1, n = 0; i <= 19 && n < 2; i++, n++) {
    const trigger = stepPrices[i];
    const amt = CFG.bps;
    const amtUSD = amt * trigger;
    const marginReq = amtUSD * 0.05;
    const isFirst = !firstCrossed[i];
    const mode = isFirst ? 'manuel' : 'auto';
    let rows = naRow('📊', 'auto', `SELL STOP ${fmtBTC(amt)} @ ${fmtUSD(trigger)}`);
    if (isFirst) {
      rows += naRow('🏦', 'manuel', `Emprunter ${fmtUSD(Math.round(amtUSD))} USDT sur AAVE (P2)`);
      rows += naRow('🏦', 'manuel', `Acheter ${fmtBTC(amt)} sur DEX → collatéral AAVE`);
      rows += naRow('📊', '', `Marge Deribit: +${fmtUSD(marginReq)} (buffer: ${fmtUSD(S.deribitEquity)})`);
      rows += naRow('🔄', '', `Aucun transfert inter-plateforme`);
    } else {
      rows += naRow('📊', '', `Marge Deribit: +${fmtUSD(marginReq)} (buffer: ${fmtUSD(S.deribitEquity)})`);
      rows += naRow('✅', '', `100% automatique — aucune action manuelle`);
    }
    nextHTML += `<div style="margin-bottom:10px;padding:10px 12px;background:var(--bg);border-radius:8px;border-left:3px solid var(--red)">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;flex-wrap:wrap">
        <span style="font-size:15px">📉</span>
        <span style="font-weight:700;color:var(--red)">BAISSE</span>
        <span style="font-weight:700">Step ${i}</span>
        <span style="color:var(--muted);font-size:12px">trigger @ ${fmtUSD(trigger)}</span>
        <span class="action-mode ${mode}" style="margin-left:auto">${mode.toUpperCase()}</span>
      </div>
      <div>${rows}</div>
    </div>`;
  }

  if (!nextHTML) nextHTML = '<div class="card-sub">Aucune action en attente</div>';

  // §POSITIONS — active Deribit shorts + pending stop orders
  let posHTML = '';
  const sortedPos = Object.entries(deribitPos).sort((a, b) => +a[0] - +b[0]);
  if (sortedPos.length) {
    posHTML = sortedPos.map(([step, pos]) => {
      const unr = CFG.bps * (pos.entry - price);
      return `<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0;font-size:11px;border-bottom:1px solid rgba(255,255,255,0.03)">
        <span>Step ${step} — SHORT ${fmtBTC(CFG.bps)} @ ${fmtUSD(pos.entry)}</span>
        <span style="font-weight:700;color:${unr >= 0 ? 'var(--green)' : 'var(--red)'}">${fmtUSD(unr)}</span>
      </div>`;
    }).join('');
  } else {
    posHTML = `<div style="font-size:11px;color:var(--muted);text-align:center;padding:4px">Aucune position ouverte</div>`;
  }

  // Pending stop orders
  let ordersHTML = '';
  // BUY STOPs (close shorts on up)
  if (cur >= 1 && deribitPos[cur]) {
    ordersHTML += `<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0;font-size:11px">
      <span style="color:var(--green)">▲ BUY STOP ${fmtBTC(CFG.bps)} @ ${fmtUSD(stepPrices[cur])}</span>
      <span class="action-mode auto" style="font-size:9px;padding:1px 6px">AUTO</span>
    </div>`;
  }
  // SELL STOP (open short on down)
  if (cur + 1 <= 19) {
    const nxtFirst = !firstCrossed[cur + 1];
    ordersHTML += `<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0;font-size:11px">
      <span style="color:var(--red)">▼ SELL STOP ${fmtBTC(CFG.bps)} @ ${fmtUSD(stepPrices[cur + 1])}</span>
      <span class="action-mode ${nxtFirst ? 'manuel' : 'auto'}" style="font-size:9px;padding:1px 6px">${nxtFirst ? 'MANUEL' : 'AUTO'}</span>
    </div>`;
  }

  // §HEADER
  $('hdr-price').textContent = fmtUSD(price);
  $('hdr-pct').textContent = pct + '%';
  $('hdr-steps').textContent = crossings;
  $('badge-step').textContent = cur === 0 ? 'ATH' : 'Step ' + cur + '/19';
  for (let i = 1; i <= 19; i++) {
    const r = $('sr-' + i);
    if (r) r.style.background = i === cur ? 'rgba(246,176,107,0.15)' : '';
  }

  // §RENDER
  $('sim-dashboard').innerHTML = `
    <div class="section" style="text-align:center;padding:12px">
      <div class="card-label">Portefeuille total (AAVE + Deribit)</div>
      <div style="font-size:26px;font-weight:800;margin:6px 0;color:var(--green)">${fmtUSD(S.portfolio)}</div>
      <div style="font-size:11px;color:var(--muted)">AAVE net: ${fmtUSD(S.aaveNet)} · Deribit: ${fmtUSD(S.deribitEquity)}</div>
    </div>

    <div class="section" style="padding:0;overflow:hidden">
      <div class="aave-hf-bar" style="background:${hfBg}">
        <span>🏦 AAVE V3 — Health Factor</span>
        <span>${S.hf.toFixed(2)}${deribitWithdrawn > 0 ? ` <span style="font-size:10px;font-weight:400">(${S.hfNoTransfer.toFixed(2)} sans transferts)</span>` : ''}</span>
      </div>
      <div style="padding:12px">
        <div style="display:flex;gap:12px">
          <div class="aave-col">
            <div class="card-label" style="margin-bottom:8px;color:var(--green)">✦ ACTIF</div>
            <div class="aave-row"><span class="aave-row-icon">₿</span><span class="aave-row-val">${fmtBTC(S.btcCol)}</span></div>
            <div style="font-size:9px;color:var(--muted);margin:-4px 0 4px 24px">P1: ${fmtBTC(S.p1Btc)} (constant) · P2: +${fmtBTC(S.p2Btc)}</div>
            ${deribitWithdrawn > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(deribitWithdrawn)} <span class="card-sub">USDC (Deribit → AAVE)</span></span></div>
            <div style="font-size:9px;color:var(--muted);margin:-4px 0 4px 24px">Gains shorts transférés cumulés</div>` : ''}
            ${CFG.usdtCol > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(CFG.usdtCol)} <span class="card-sub">USDT init</span></span></div>` : ''}
            <div style="flex:1"></div>
            <div class="aave-total"><div class="card-sub">Total</div><div style="font-weight:700">${fmtUSD(S.colUSD)}</div></div>
          </div>
          <div class="divider-v"></div>
          <div class="aave-col">
            <div class="card-label" style="margin-bottom:8px;color:var(--red)">✦ PASSIF</div>
            ${S.p2Debt > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(S.p2Debt)} <span class="card-sub">P2 dette</span></span></div>` : ''}
            ${CFG.debtUSDT > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(CFG.debtUSDT)} <span class="card-sub">USDT init</span></span></div>` : ''}
            ${CFG.debtUSDC > 0 ? `<div class="aave-row"><span class="aave-row-icon">💵</span><span class="aave-row-val">${fmtUSD(CFG.debtUSDC)} <span class="card-sub">USDC init</span></span></div>` : ''}
            ${S.totalDebt === 0 ? `<div class="aave-row"><span class="aave-row-icon">✅</span><span class="aave-row-val" style="color:var(--green)">Aucune dette</span></div>` : ''}
            <div style="flex:1"></div>
            <div class="aave-total"><div class="card-sub">Total</div><div style="font-weight:700;color:var(--red)">${fmtUSD(S.totalDebt)}</div></div>
          </div>
        </div>
        <div class="aave-footer">
          <span>LTV: ${S.ltv.toFixed(1)}%</span><span>Net: ${fmtUSD(S.aaveNet)}</span><span class="orange">Liq: ${fmtUSD(S.liq)}</span>
        </div>
      </div>
    </div>

    <div class="section" style="padding:0;overflow:hidden">
      <div style="padding:8px 12px;background:rgba(96,165,250,0.12);display:flex;justify-content:space-between;align-items:center;font-size:13px;font-weight:700">
        <span>📊 Deribit — Futures Hedge</span>
        <span>${S.shortCount} short${S.shortCount !== 1 ? 's' : ''} · ${fmtBTC(S.shortBtc)}</span>
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
            <div class="card-label">Marge req. (5%)</div>
            <div style="font-weight:700;margin-top:2px">${fmtUSD(S.deribitIM)}</div>
          </div>
        </div>
        ${S.needsTopup > 0 ? `<div style="margin-top:8px;padding:6px;background:rgba(248,113,113,0.1);border-radius:6px;font-size:11px;color:var(--red);text-align:center;font-weight:700">⚠️ Transférer ~${fmtUSD(S.needsTopup)} USDC AAVE → Deribit</div>` : ''}
        ${S.transferable > 0 ? `<div style="margin-top:8px;padding:6px;background:rgba(110,231,160,0.1);border-radius:6px;font-size:11px;color:var(--green);text-align:center;font-weight:700">📊→🏦 ${fmtUSD(S.transferable)} USDC transférables vers AAVE</div>` : ''}
        <div style="margin-top:10px;padding-top:8px;border-top:1px solid var(--border)">
          <div style="font-size:10px;text-transform:uppercase;color:var(--muted);letter-spacing:0.5px;margin-bottom:4px">Positions ouvertes</div>
          ${posHTML}
        </div>
        <div style="margin-top:8px;padding-top:8px;border-top:1px solid var(--border)">
          <div style="font-size:10px;text-transform:uppercase;color:var(--muted);letter-spacing:0.5px;margin-bottom:4px">Ordres stop en attente</div>
          ${ordersHTML || '<div style="font-size:11px;color:var(--muted);text-align:center;padding:4px">Aucun</div>'}
        </div>
      </div>
    </div>

    ${S.contangoYear > 0 ? `<div class="section" style="text-align:center">
      <h3>💰 Contango estimé (${CFG.contango}%/an)</h3>
      <div class="card-value green">${fmtUSD(S.contangoYear)}/an</div>
      <div class="card-sub">${fmtUSD(S.contangoMonth)}/mois sur ${fmtUSD(S.deribitNotional)} notionnel</div>
    </div>` : ''}

    <div class="section" style="text-align:center">
      <h3>🎯 Collatéral @ ATH (${fmtUSD(CFG.ATH)})</h3>
      <div class="card-value green" style="font-size:24px">${fmtBTC(totalBtcATH)}</div>
      <div class="card-sub" style="font-size:13px;margin-top:4px">${fmtUSD(totalBtcATH * CFG.ATH)} · 100% BTC</div>
      <div style="margin-top:10px;padding-top:8px;border-top:1px solid var(--border);font-size:11px;color:var(--muted);display:flex;justify-content:space-around;flex-wrap:wrap;gap:4px">
        <span>P1: ${fmtBTC(CFG.wbtc)}</span>
        <span class="green">P2: +${fmtBTC(p2Profit / CFG.ATH)}</span>
        ${deribitWithdrawn > 0 ? `<span class="green">USDC: +${fmtBTC(deribitWithdrawn / CFG.ATH)}</span>` : ''}
        <span class="${deribitEquityATHproj >= 0 ? 'green' : 'red'}">Deribit: ${fmtBTC(deribitEquityATHproj / CFG.ATH)}</span>
        ${CFG.ret > 0 ? `<span class="red">−${fmtBTC(CFG.ret)}</span>` : ''}
      </div>
    </div>

    <div class="section"><h3>🎯 Prochaines actions</h3>${nextHTML}</div>

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
      snap: { hf: S.hf.toFixed(2), col: fmtUSD(S.colUSD), debt: fmtUSD(S.totalDebt),
              deribit: fmtUSD(S.deribitEquity), contango: fmtUSD(S.contangoYear), portfolio: fmtUSD(S.portfolio) } });
    renderLog();
  }
  prevStep = cur;
}
