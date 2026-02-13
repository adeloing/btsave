#!/usr/bin/env node
/**
 * Grid Gains — Simulation calibrée sur données réelles BTC 2021-2026
 * 
 * Sources (Yahoo Finance BTC-USD daily):
 *   - Volatilité annualisée moyenne: 47.4%
 *   - Crossings réels (step $6,300): 4.9/mois en moyenne
 *   - Durée moyenne entre ATH majeurs: 13 mois
 *   - Par année: 2021=7.3/mo, 2022=2.9/mo, 2023=1.2/mo, 2024=6.0/mo, 2025=7.0/mo, 2026=9.5/mo
 */

const ATH = 126000;
const CAPTURE = 100;  // $ net par crossing après équilibrage

// === DONNÉES HISTORIQUES RÉELLES ===
const historicalVol = {
  '2021': 63.1, '2022': 53.5, '2023': 36.1,
  '2024': 44.2, '2025': 34.8, '2026': 58.8,
  avg: 47.4
};

const historicalCrossings = {
  '2021': 7.3, '2022': 2.9, '2023': 1.2,
  '2024': 6.0, '2025': 7.0, '2026': 9.5,
  avg: 4.9
};

const avgMonthsBetweenATH = 13;

console.log('╔══════════════════════════════════════════════════════════════════════════════════╗');
console.log('║  ⚡ SIMULATION GRID P3 — CALIBRÉE DONNÉES RÉELLES BTC (2021-2026)              ║');
console.log('╚══════════════════════════════════════════════════════════════════════════════════╝');

console.log('\n📊 DONNÉES HISTORIQUES');
console.log('┌──────┬──────────────┬───────────────────┐');
console.log('│ Year │ Vol annuelle │ Crossings/mois    │');
console.log('├──────┼──────────────┼───────────────────┤');
for (const y of ['2021','2022','2023','2024','2025','2026']) {
  console.log(`│ ${y} │ ${(historicalVol[y]+'%').padStart(11)} │ ${historicalCrossings[y].toFixed(1).padStart(5)}/mois         │`);
}
console.log('├──────┼──────────────┼───────────────────┤');
console.log(`│ MOY. │ ${(historicalVol.avg+'%').padStart(11)} │ ${historicalCrossings.avg.toFixed(1).padStart(5)}/mois         │`);
console.log('└──────┴──────────────┴───────────────────┘');
console.log(`\nDurée moyenne entre ATH majeurs: ${avgMonthsBetweenATH} mois`);

// === SCÉNARIO PRINCIPAL: Cycle ATH → ATH ===
console.log('\n\n══════════════════════════════════════════════════════');
console.log('  🎯 SCÉNARIO PRINCIPAL: 1 cycle complet (ATH → ATH)');
console.log('══════════════════════════════════════════════════════');

const duration = avgMonthsBetweenATH; // 13 mois
const crossingsPerMonth = historicalCrossings.avg; // 4.9
const totalCrossings = Math.round(crossingsPerMonth * duration);

// Prix moyen pendant un cycle: le prix descend puis remonte
// Historiquement BTC drawdown moyen ~55% depuis ATH avant recovery
// → prix moyen du cycle ≈ 65-70% de l'ATH
const avgPricePct = 0.67;
const avgPrice = Math.round(ATH * avgPricePct);

const totalGainUSD = totalCrossings * CAPTURE;
const btcAccum = totalGainUSD / avgPrice;
const valueATH = btcAccum * ATH;
const multiplier = ATH / avgPrice;
const roiUSD = ((valueATH / totalGainUSD - 1) * 100).toFixed(0);

console.log(`\n  Durée:              ${duration} mois`);
console.log(`  Crossings/mois:     ${crossingsPerMonth} (moyenne historique réelle)`);
console.log(`  Total crossings:    ${totalCrossings}`);
console.log(`  Capture/crossing:   $${CAPTURE} net`);
console.log(`  Prix moyen cycle:   $${avgPrice.toLocaleString()} (~${(avgPricePct*100).toFixed(0)}% de l'ATH)`);
console.log(`  Volatilité:         ${historicalVol.avg}% annualisée`);
console.log(`\n  ┌─────────────────────────────────────────────────┐`);
console.log(`  │  Gains USD bruts:       $${totalGainUSD.toLocaleString().padStart(7)}                  │`);
console.log(`  │  BTC accumulés:         ${btcAccum.toFixed(4)} ₿                │`);
console.log(`  │  Valeur à l'ATH:        $${Math.round(valueATH).toLocaleString().padStart(7)}  (×${multiplier.toFixed(2)})       │`);
console.log(`  └─────────────────────────────────────────────────┘`);

// === DECOMPOSITION PAR PHASE DU CYCLE ===
console.log('\n\n══════════════════════════════════════════════════════');
console.log('  📈 DÉCOMPOSITION PAR PHASE DU CYCLE (13 mois)');
console.log('══════════════════════════════════════════════════════');

// Typical cycle: crash (3mo, low cross), bear (4mo, very low), recovery (3mo, med), euphoria (3mo, high)
const phases = [
  { name: 'Correction',  months: 3, crossMo: 6.0, avgPrice: Math.round(ATH * 0.75), desc: 'Chute post-ATH, forte activité' },
  { name: 'Bear/Range',  months: 4, crossMo: 2.0, avgPrice: Math.round(ATH * 0.50), desc: 'Consolidation, faible vol' },
  { name: 'Recovery',    months: 3, crossMo: 5.5, avgPrice: Math.round(ATH * 0.65), desc: 'Reprise, vol croissante' },
  { name: 'Euphorie',    months: 3, crossMo: 8.0, avgPrice: Math.round(ATH * 0.85), desc: 'Sprint vers ATH, très actif' },
];

console.log(`\n${'Phase'.padEnd(14)} | Mois | Cross/mo | Total | Prix moy | Gain $ | BTC accum`);
console.log(`${'─'.repeat(14)}-+${'─'.repeat(5)}-+${'─'.repeat(9)}-+${'─'.repeat(6)}-+${'─'.repeat(9)}-+${'─'.repeat(7)}-+${'─'.repeat(10)}`);

let totalBTC = 0;
let totalUSD = 0;
for (const p of phases) {
  const cross = Math.round(p.crossMo * p.months);
  const gain = cross * CAPTURE;
  const btc = gain / p.avgPrice;
  totalBTC += btc;
  totalUSD += gain;
  console.log(`${p.name.padEnd(14)} | ${String(p.months).padStart(4)} | ${p.crossMo.toFixed(1).padStart(8)} | ${String(cross).padStart(5)} | $${(p.avgPrice/1000).toFixed(0)}k`.padEnd(62) + ` | $${gain.toLocaleString().padStart(5)} | ${btc.toFixed(4)} ₿`);
}

console.log(`${'─'.repeat(14)}-+${'─'.repeat(5)}-+${'─'.repeat(9)}-+${'─'.repeat(6)}-+${'─'.repeat(9)}-+${'─'.repeat(7)}-+${'─'.repeat(10)}`);
const phaseTotalCross = phases.reduce((s, p) => s + Math.round(p.crossMo * p.months), 0);
console.log(`${'TOTAL'.padEnd(14)} | ${String(duration).padStart(4)} |     avg   | ${String(phaseTotalCross).padStart(5)} |           | $${totalUSD.toLocaleString().padStart(5)} | ${totalBTC.toFixed(4)} ₿`);

const phaseValueATH = totalBTC * ATH;
console.log(`\n  Valeur totale à l'ATH: $${Math.round(phaseValueATH).toLocaleString()} (${totalBTC.toFixed(4)} ₿ × $${ATH.toLocaleString()})`);
console.log(`  Note: la phase bear accumule peu de BTC en volume, mais au meilleur prix`);

// === MULTI-CYCLE ===
console.log('\n\n══════════════════════════════════════════════════════');
console.log('  🔄 PROJECTION MULTI-CYCLES');
console.log('══════════════════════════════════════════════════════');
console.log(`\n  (hypothèse: mêmes paramètres par cycle, gains réinvestis en BTC)\n`);
console.log(`  ${'Cycles'.padEnd(10)} | Durée    | BTC total | Valeur @ATH`);
console.log(`  ${'─'.repeat(10)}-+${'─'.repeat(9)}-+${'─'.repeat(10)}-+${'─'.repeat(12)}`);

for (let c = 1; c <= 4; c++) {
  const btcTotal = totalBTC * c; // simplified (not compound)
  const val = btcTotal * ATH;
  const years = (c * duration / 12).toFixed(1);
  console.log(`  ${(c + ' cycle' + (c>1?'s':'')).padEnd(10)} | ${(years + ' ans').padStart(8)} | ${btcTotal.toFixed(4).padStart(9)} ₿ | $${Math.round(val).toLocaleString()}`);
}

console.log('\n\n═══ RÉSUMÉ FINAL ═══');
console.log(`\nUn cycle moyen ATH→ATH (~13 mois) avec la volatilité historique de BTC`);
console.log(`génère environ ${totalBTC.toFixed(4)} BTC de gains grid, soit ~$${Math.round(phaseValueATH).toLocaleString()} à l'ATH.`);
console.log(`\nC'est un rendement de ~${(totalBTC * 100 / 0.1).toFixed(0)}% sur le collatéral engagé (0.1 BTC/step).`);
console.log(`Sur 4 cycles (~4.3 ans), ça donne ~${(totalBTC * 4).toFixed(2)} BTC → $${Math.round(totalBTC * 4 * ATH).toLocaleString()} @ATH.`);
