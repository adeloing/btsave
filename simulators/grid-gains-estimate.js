#!/usr/bin/env node
/**
 * Grid Gains Estimator
 * 
 * Models expected P3 grid profits across 9 scenarios:
 * 3 durations × 3 volatility levels
 * 
 * Key assumptions:
 * - Capture per crossing: $100 net (0.1 BTC × $1,000 spread, after rebalancing)
 * - Gains kept in BTC → sold at ATH ($126,000)
 * - BTC price trends upward toward ATH over time
 * - Crossings/month estimated from BTC annualized volatility + step spacing
 */

const ATH = 126000;
const CURRENT_PRICE = 69000;
const CAPTURE_PER_CROSSING = 100; // $ net after rebalancing
const STEP_SPACING = 6300;

// --- Volatility → Crossings/month model ---
// Based on random walk: crossings ≈ daily_moves / step_spacing
// σ_daily = price × ann_vol / √252
// Expected monthly crossings ≈ 30 × σ_daily / (step_spacing × √(π/2))
// Then adjusted down by ~0.6 for discreteness and mean-reversion
function crossingsPerMonth(annualizedVol, avgPrice) {
  const dailyVol = avgPrice * annualizedVol / Math.sqrt(252);
  const raw = 30 * dailyVol / (STEP_SPACING * Math.sqrt(Math.PI / 2));
  return raw * 0.55; // empirical adjustment for discrete grid + clustering
}

// Volatility scenarios (annualized)
const VOL = {
  low:  { label: 'Basse',   ann: 0.30, desc: '~30% ann. (range-bound, consolidation)' },
  med:  { label: 'Moyenne', ann: 0.55, desc: '~55% ann. (typique BTC, tendance modérée)' },
  high: { label: 'Haute',   ann: 0.85, desc: '~85% ann. (bull/bear swings, forte activité)' },
};

// Duration scenarios with assumed average BTC price during period
// (price trends toward ATH → gains buy less BTC over time)
const DURATION = {
  short:  { months: 3,  label: 'Court (3 mois)',   avgPrice: 72000,  desc: 'Prix moyen ~$72k' },
  medium: { months: 10, label: 'Moyen (10 mois)',  avgPrice: 85000,  desc: 'Prix moyen ~$85k' },
  long:   { months: 18, label: 'Long (18 mois)',   avgPrice: 98000,  desc: 'Prix moyen ~$98k' },
};

console.log('╔══════════════════════════════════════════════════════════════════════════════╗');
console.log('║           ⚡ ESTIMATION DES GAINS GRID P3 — 9 SCÉNARIOS                    ║');
console.log('╠══════════════════════════════════════════════════════════════════════════════╣');
console.log('║ Capture par crossing: $100 net (après équilibrage)                          ║');
console.log('║ Gains conservés en BTC → revendus à l\'ATH ($126,000)                        ║');
console.log('╚══════════════════════════════════════════════════════════════════════════════╝');
console.log();

const results = [];

for (const [dk, dur] of Object.entries(DURATION)) {
  console.log(`\n━━━ ${dur.label.toUpperCase()} — ${dur.desc} ━━━`);
  console.log(`${'Volatilité'.padEnd(12)} | Cross/mois | Total cross | Gain $ | BTC accum. | Valeur @ATH | Multipli.`);
  console.log(`${'─'.repeat(12)}-+-${'─'.repeat(10)}-+-${'─'.repeat(12)}-+-${'─'.repeat(7)}-+-${'─'.repeat(11)}-+-${'─'.repeat(12)}-+-${'─'.repeat(9)}`);

  for (const [vk, vol] of Object.entries(VOL)) {
    const cpm = crossingsPerMonth(vol.ann, dur.avgPrice);
    const totalCrossings = Math.round(cpm * dur.months);
    const totalGainUSD = totalCrossings * CAPTURE_PER_CROSSING;
    
    // BTC accumulated: each $100 gain buys BTC at the average price during the period
    const btcAccum = totalGainUSD / dur.avgPrice;
    
    // Value when sold at ATH
    const valueAtATH = btcAccum * ATH;
    
    // Multiplier vs holding gains in USD
    const multiplier = valueAtATH / totalGainUSD;

    const row = {
      duration: dur.label,
      volatility: vol.label,
      crossingsPerMonth: cpm.toFixed(1),
      totalCrossings,
      gainUSD: totalGainUSD,
      btcAccum: btcAccum.toFixed(4),
      valueATH: Math.round(valueAtATH),
      multiplier: multiplier.toFixed(2),
    };
    results.push(row);

    console.log(
      `${vol.label.padEnd(12)} | ${cpm.toFixed(1).padStart(10)} | ${String(totalCrossings).padStart(12)} | ${('$' + totalGainUSD.toLocaleString()).padStart(7)} | ${btcAccum.toFixed(4).padStart(10)} ₿ | ${('$' + Math.round(valueAtATH).toLocaleString()).padStart(12)} | ${multiplier.toFixed(2).padStart(6)}x`
    );
  }
}

// Summary
console.log('\n\n═══ RÉSUMÉ ═══');
console.log(`\nMeilleur cas (18 mois, haute vol):  ${results[results.length-1].btcAccum} BTC → $${results[results.length-1].valueATH.toLocaleString()} @ATH`);
console.log(`Cas moyen (10 mois, vol moyenne):   ${results[4].btcAccum} BTC → $${results[4].valueATH.toLocaleString()} @ATH`);
console.log(`Pire cas (3 mois, basse vol):        ${results[0].btcAccum} BTC → $${results[0].valueATH.toLocaleString()} @ATH`);

console.log('\n═══ HYPOTHÈSES ═══');
console.log('• Le grid capture $100 net par crossing (0.1 BTC × spread $1,000)');
console.log('• Les crossings sont estimés via un modèle de marche aléatoire ajusté');
console.log('  (vol annualisée → vol journalière → crossings mensuels, facteur 0.55)');
console.log('• Le prix BTC moyen augmente avec la durée (trending vers ATH)');
console.log('• Les gains sont immédiatement convertis en BTC au prix moyen de la période');
console.log('• Pas de frais de trading inclus (Deribit maker ~0.01%, négligeable)');
console.log('• Pas de funding rate inclus (peut être + ou -, historiquement ~net 0)');

// Output JSON for programmatic use
const jsonOut = JSON.stringify(results, null, 2);
require('fs').writeFileSync('/home/xou/Hedge/simulators/grid-gains-results.json', jsonOut);
console.log('\n→ Résultats JSON: simulators/grid-gains-results.json');
