#!/usr/bin/env node
/**
 * Spread Width Analysis
 * 
 * Compare different buy/sell spread widths on real BTC price data.
 * Current: spread $1,000 (buy at floor, sell at floor+1000) → $100/round-trip
 * 
 * Tests: $1k, $2k, $3k, $4k, $5k spreads
 * Uses Yahoo Finance daily data to count actual round-trips.
 */

const https = require('https');

function fetchBTCData() {
  return new Promise((resolve, reject) => {
    const url = 'https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD?interval=1d&range=5y';
    https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => resolve(JSON.parse(d)));
    }).on('error', reject);
  });
}

async function main() {
  const raw = await fetchBTCData();
  const result = raw.chart.result[0];
  const ts = result.timestamp;
  const quotes = result.indicators.quote[0];
  
  // Get OHLC data from 2021+
  const prices = [];
  for (let i = 0; i < ts.length; i++) {
    if (ts[i] >= 1609459200 && quotes.close[i] && quotes.high[i] && quotes.low[i]) {
      prices.push({
        ts: ts[i],
        open: quotes.open[i],
        high: quotes.high[i],
        low: quotes.low[i],
        close: quotes.close[i],
      });
    }
  }
  
  const ATH = 126000;
  const STEP_SIZE = 6300;
  const BTC_PER_TRADE = 0.1;
  const months = prices.length / 30;
  
  console.log('╔══════════════════════════════════════════════════════════════════════════╗');
  console.log('║  ⚡ ANALYSE SPREAD — IMPACT DE L\'ÉCART BUY/SELL SUR LES GAINS GRID     ║');
  console.log('╚══════════════════════════════════════════════════════════════════════════╝');
  console.log(`\nDonnées: ${prices.length} jours (${months.toFixed(0)} mois) de prix BTC-USD daily`);
  console.log(`Step spacing: $${STEP_SIZE.toLocaleString()} | Taille: ${BTC_PER_TRADE} BTC/trade\n`);
  
  // For each spread width, simulate grid round-trips
  // A "round-trip" = price goes through buy_level then through sell_level (or vice versa)
  // We track for each step whether BUY or SELL triggered, then count completed pairs
  
  const spreads = [
    { width: 1000, label: '$1k (actuel)',   buyOffset: 0,    sellOffset: 0 },
    { width: 2000, label: '$2k (-500/+500)', buyOffset: -500,  sellOffset: +500 },
    { width: 3000, label: '$3k (-1k/+1k)',   buyOffset: -1000, sellOffset: +1000 },
    { width: 4000, label: '$4k (-1.5k/+1.5k)', buyOffset: -1500, sellOffset: +1500 },
    { width: 5000, label: '$5k (-2k/+2k)',   buyOffset: -2000, sellOffset: +2000 },
  ];
  
  // Build step table
  const steps = [];
  for (let n = 1; n <= 19; n++) {
    const prix = ATH - n * STEP_SIZE;
    const baseBuy = Math.floor(prix / 1000) * 1000;
    const baseSell = baseBuy + 1000;
    steps.push({ n, prix, baseBuy, baseSell });
  }
  
  const results = [];
  
  for (const spread of spreads) {
    // For each step, define actual buy/sell levels
    const stepLevels = steps.map(s => ({
      n: s.n,
      buy: s.baseBuy + spread.buyOffset,   // lower = more room for price to rise into
      sell: s.baseSell + spread.sellOffset, // higher = more room for price to fall into
    }));
    
    // Track state per step: null, 'bought' (waiting to sell), 'sold' (waiting to buy)
    const state = {};
    let roundTrips = 0;
    let totalCapture = 0;
    
    for (const day of prices) {
      for (const sl of stepLevels) {
        const key = sl.n;
        
        // Check if daily range touches our levels
        // BUY triggers when price rises through buy level (low was below, high was above)
        const buyTriggered = day.low <= sl.buy && day.high >= sl.buy;
        // SELL triggers when price falls through sell level (high was above, low was below)
        const sellTriggered = day.high >= sl.sell && day.low <= sl.sell;
        
        if (!state[key]) {
          // No position - look for initial trigger
          if (buyTriggered && day.close > sl.buy) {
            state[key] = 'bought';
          } else if (sellTriggered && day.close < sl.sell) {
            state[key] = 'sold';
          }
        } else if (state[key] === 'bought' && sellTriggered) {
          // Complete round-trip: bought then sold
          roundTrips++;
          totalCapture += (sl.sell - sl.buy) * BTC_PER_TRADE;
          state[key] = null;
        } else if (state[key] === 'sold' && buyTriggered) {
          // Complete round-trip: sold then bought back
          roundTrips++;
          totalCapture += (sl.sell - sl.buy) * BTC_PER_TRADE;
          state[key] = null;
        }
      }
    }
    
    const capturePerRT = (stepLevels[0].sell - stepLevels[0].buy) * BTC_PER_TRADE;
    const perMonth = roundTrips / months;
    const capturePerMonth = totalCapture / months;
    
    // Convert to BTC (assume avg price ~$80k during period)
    const avgPrice = 80000;
    const btcAccum = totalCapture / avgPrice;
    const valueATH = btcAccum * ATH;
    
    results.push({
      spread, roundTrips, totalCapture, capturePerRT, perMonth, capturePerMonth,
      btcAccum, valueATH
    });
  }
  
  // Display results
  console.log('═══ RÉSULTATS PAR SPREAD ═══\n');
  console.log(`${'Spread'.padEnd(22)} | $/RT  | RTs total | RT/mois | Gain $/mois | Gain total | BTC accum | @ATH`);
  console.log(`${'─'.repeat(22)}-+${'─'.repeat(6)}-+${'─'.repeat(10)}-+${'─'.repeat(8)}-+${'─'.repeat(12)}-+${'─'.repeat(11)}-+${'─'.repeat(10)}-+${'─'.repeat(10)}`);
  
  const baseline = results[0];
  for (const r of results) {
    const pctVsBase = ((r.totalCapture / baseline.totalCapture - 1) * 100).toFixed(0);
    const sign = r.totalCapture >= baseline.totalCapture ? '+' : '';
    console.log(
      `${r.spread.label.padEnd(22)} | $${r.capturePerRT.toFixed(0).padStart(3)} | ${String(r.roundTrips).padStart(9)} | ${r.perMonth.toFixed(1).padStart(7)} | $${r.capturePerMonth.toFixed(0).padStart(5)}/mois | $${r.totalCapture.toLocaleString().padStart(9)} | ${r.btcAccum.toFixed(4).padStart(8)} ₿ | $${Math.round(r.valueATH).toLocaleString().padStart(7)} ${sign}${pctVsBase}%`
    );
  }
  
  // Risk analysis
  console.log('\n\n═══ ANALYSE DES RISQUES ═══\n');
  
  console.log('┌─────────────────────────────────────────────────────────────────────────┐');
  console.log('│ SPREAD     │ AVANTAGES                    │ RISQUES                      │');
  console.log('├─────────────────────────────────────────────────────────────────────────┤');
  console.log('│ $1k actuel │ ✅ Max round-trips           │ ⚡ Slippage fréquent         │');
  console.log('│            │ ✅ Hedge précis pour P1/P2   │ ⚡ Plus de frais cumulés     │');
  console.log('├─────────────────────────────────────────────────────────────────────────┤');
  console.log('│ $2k        │ ✅ Sweet spot possible       │ ⚠️ Hedge légèrement décalé  │');
  console.log('│            │ ✅ Moins de frais            │ ⚠️ Gap risk +$500            │');
  console.log('├─────────────────────────────────────────────────────────────────────────┤');
  console.log('│ $3k        │ ✅ Capture 3× par RT         │ ⚠️ Moins de fills           │');
  console.log('│            │ ✅ Bon si forte vol          │ ⚠️ Gap risk +$1k             │');
  console.log('├─────────────────────────────────────────────────────────────────────────┤');
  console.log('│ $4-5k      │ 🔶 Très gros par RT         │ ❌ Fills rares en bear       │');
  console.log('│            │                              │ ❌ Hedge inutilisable P1/P2  │');
  console.log('│            │                              │ ❌ Basis risk élevé           │');
  console.log('└─────────────────────────────────────────────────────────────────────────┘');
  
  console.log('\n═══ RISQUES DÉTAILLÉS ═══\n');
  console.log('1. BASIS RISK (risque de base)');
  console.log('   Le grid hedge P1/P2 pendant le délai d\'exécution on-chain.');
  console.log('   Plus le spread est large, plus le prix d\'entrée du hedge s\'écarte');
  console.log('   du prix réel de l\'opération AAVE → perte de précision.');
  console.log('   • $1k spread: hedge à ±$500 du prix théorique');
  console.log('   • $3k spread: hedge à ±$1,500 du prix théorique');
  console.log('   • $5k spread: hedge à ±$2,500 → quasi inutile comme hedge\n');
  
  console.log('2. FILL PROBABILITY');
  console.log('   En période de basse vol (2023: 36% ann.), les oscillations sont petites.');
  console.log('   Un spread $3k+ peut rester des semaines sans round-trip complet.\n');
  
  console.log('3. GAP RISK');
  console.log('   Si le prix gap à travers le spread (flash crash/pump), le stop');
  console.log('   s\'exécute au prix du marché, pas au prix limite. Plus le spread');
  console.log('   est large, plus les ordres sont loin → plus de slippage potentiel.\n');
  
  console.log('4. CAPITAL LOCKUP');
  console.log('   Marge Deribit bloquée par les ordres. Spread plus large = pas d\'impact');
  console.log('   sur la marge (même nombre d\'ordres), mais positions ouvertes plus longtemps.\n');
  
  // Recommendation
  const best = results.reduce((a, b) => a.totalCapture > b.totalCapture ? a : b);
  console.log('═══ RECOMMANDATION ═══\n');
  console.log(`Le spread optimal sur données historiques: ${best.spread.label}`);
  console.log(`(+${((best.totalCapture / baseline.totalCapture - 1) * 100).toFixed(0)}% vs spread actuel $1k)\n`);
  console.log('MAIS il faut garder en tête que le grid a un double rôle:');
  console.log('  1. Capturer de la valeur sur les oscillations (→ optimiser le spread)');
  console.log('  2. Hedger P1/P2 pendant l\'exécution on-chain (→ garder le spread serré)');
  console.log('\n💡 COMPROMIS SUGGÉRÉ: spread $2k (-$500/+$500)');
  console.log('   • Capture $200/RT au lieu de $100');
  console.log('   • Hedge toujours utilisable (±$500 de décalage seulement)');
  console.log('   • Réduction des frais de ~50%');
  console.log('   • Risque modéré et contrôlé');
}

main().catch(console.error);
