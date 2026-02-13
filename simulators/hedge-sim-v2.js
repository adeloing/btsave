// Hedge Simulator v2 — Full Perps Grid — Kei ⚡

class HedgeSimV2 {
  constructor(ath, { initBtc = 2, fundingPer8h = 0.0003, contractSize = 0.1 } = {}) {
    this.initBtc = initBtc;
    this.fundingPer8h = fundingPer8h;
    this.contractSize = contractSize;
    this.perpPnl = 0;       // P&L cumulé des perps
    this.fundingCost = 0;   // coût funding cumulé
    this.gridProfit = 0;    // profit de grille cumulé
    this.onchainTxs = 0;    // nombre de tx on-chain
    this.perpTxs = 0;       // nombre d'ordres perp exécutés

    // P1+P2 state
    this.btc = initBtc;     // WBTC en collatéral
    this.cash = 0;          // USDT en collatéral (emprunté)
    this.debt = 0;          // dette totale USDT
    this.btcAccum = 0;      // WBTC accumulé via P2

    // Step tracking
    this.perp = null;       // position perp ouverte { type, entryPrice, size }
    this.setATH(ath);
  }

  setATH(ath) {
    this.ath = ath;
    this.pas = 0.05 * ath;
    this.lastStep = 0;
    this.lastActivated = null;
    this.ref = Array.from({ length: 19 }, (_, i) => {
      const prix = ath - (i + 1) * this.pas;
      const lo = Math.floor(prix / 1000) * 1000;
      return { step: i + 1, prix, lo, hi: lo + 1000, first: false };
    });
  }

  r(s) { return this.ref[s - 1]; }

  // Open/close perp position
  openPerp(type, price, step, out) {
    // Close existing perp if any
    if (this.perp) this.closePerp(price, out);

    this.perp = { type, entry: price, size: this.contractSize, step };
    this.perpTxs++;
    out.push(`  ⚡ OPEN ${type} 0.1 BTC perp @ ${price}`);
  }

  closePerp(price, out) {
    if (!this.perp) return;
    const { type, entry, size } = this.perp;
    const pnl = type === 'SHORT'
      ? (entry - price) * size
      : (price - entry) * size;
    this.perpPnl += pnl;
    if (pnl > 0) this.gridProfit += pnl;
    this.perpTxs++;
    const sign = pnl >= 0 ? '+' : '';
    out.push(`  ⚡ CLOSE ${type} perp @ ${price} (entrée: ${entry}) → ${sign}${pnl.toFixed(0)} USD`);
    this.perp = null;
  }

  // Apply funding cost for open perp (per tick, assume 8h between ticks for simplicity)
  applyFunding(price) {
    if (!this.perp) return 0;
    const cost = price * this.perp.size * this.fundingPer8h;
    this.fundingCost += cost;
    return cost;
  }

  tick(prix, hoursElapsed = 8) {
    const out = [];

    // Apply funding on open perp
    const funding = this.applyFunding(prix);

    // New ATH check
    const rounded = Math.floor(prix / 1000) * 1000;
    if (rounded >= this.ath + 1000) {
      out.push(`🔺 NOUVEL ATH! ${rounded} (ancien: ${this.ath})`);
      if (this.perp) this.closePerp(prix, out);
      this.setATH(rounded);
      return out;
    }

    // Back above ATH
    if (prix >= this.ath && this.lastStep > 0) {
      out.push(`🏔️ Retour au-dessus de l'ATH (${this.ath})`);
      if (this.perp) this.closePerp(prix, out);
      this.lastStep = 0;
      return out;
    }

    // Determine target step
    let target = 0;
    for (const s of this.ref) {
      if (!s.first) {
        if (prix < s.prix) target = s.step;
      } else if (this.lastStep < s.step) {
        if (prix < s.hi) target = s.step;
      } else if (prix <= s.lo) {
        target = s.step;
      }
    }

    const skip = this.lastActivated;

    // Going DOWN
    if (target > this.lastStep) {
      for (let s = this.lastStep + 1; s <= target; s++) {
        if (s === skip) { out.push(`⏭️ Skip palier ${s}`); continue; }
        const ref = this.r(s);

        if (!ref.first) {
          // PREMIER FRANCHISSEMENT: juste emprunter (P1+P2 fusionné)
          ref.first = true;
          this.lastActivated = s;
          const borrowAmt = +(0.1 * prix).toFixed(0);
          this.debt += borrowAmt;
          this.cash += borrowAmt;
          this.onchainTxs++;

          if (s === 1) {
            out.push(`⚠️ Palier 1 — prix: ${prix} — BORROW ${borrowAmt} USDT (collatéral)`);
          } else {
            out.push(`⚠️ Palier ${s} — prix: ${prix} — BORROW ${borrowAmt} USDT (collatéral)`);
          }
          // Pas de hedge nécessaire (1 tx atomique)
        } else {
          // RETOUR: hedge perp + tx on-chain à faire
          out.push(`↘️ Retour palier ${s} (baisse) — prix: ${prix}`);
          this.openPerp('SHORT', prix, s, out);
          out.push(`  🔗 TODO on-chain: swap 0.1 WBTC → USDT + buy 0.1 WBTC`);
          this.lastActivated = s;
        }
      }
      this.lastStep = target;
    }

    // Going UP
    if (target < this.lastStep) {
      for (let s = this.lastStep; s > target; s--) {
        if (s === skip) { out.push(`⏭️ Skip palier ${s}`); continue; }

        out.push(`↗️ ${s === 1 ? 'Traverse' : 'Quitte'} palier ${s} (hausse) — prix: ${prix}`);
        this.openPerp('LONG', prix, s, out);
        out.push(`  🔗 TODO on-chain: swap USDT → 0.1 WBTC + rembourser`);
        this.lastActivated = s;
      }
      this.lastStep = target;
    }

    return out;
  }

  // Simulate on-chain execution (close perp at execution price)
  executeOnchain(prix, out) {
    if (!this.perp) return ['Pas de perp ouvert.'];
    if (!out) out = [];
    this.closePerp(prix, out);
    this.onchainTxs++;
    out.push(`  ✅ Tx on-chain exécutée @ ${prix}`);
    return out;
  }

  status() {
    const lines = [
      `ATH: ${this.ath} | Palier: ${this.lastStep}`,
      `Collatéral: ${this.btc} WBTC + ${this.cash} USDT | Dette: ${this.debt} USDT`,
      `BTC accumulé (P2): ${this.btcAccum}`,
      `Perp ouvert: ${this.perp ? this.perp.type + ' @ ' + this.perp.entry : 'aucun'}`,
      `Grid profit: +${this.gridProfit.toFixed(0)} USD | Funding: -${this.fundingCost.toFixed(0)} USD | Net perp: ${(this.gridProfit - this.fundingCost).toFixed(0)} USD`,
      `Transactions: ${this.perpTxs} perp + ${this.onchainTxs} on-chain`
    ];
    return lines.join('\n');
  }

  table() {
    const h = 'Step |     Prix | Strike Lo | Strike Hi | ✓';
    const sep = '-----|----------|-----------|-----------|--';
    const rows = this.ref.map(r =>
      `  ${String(r.step).padStart(2)} | ${String(r.prix).padStart(8)} | ${String(r.lo).padStart(9)} | ${String(r.hi).padStart(9)} | ${r.first ? '✓' : ' '}${r.step === this.lastStep ? ' ◄' : ''}`
    );
    return [h, sep, ...rows].join('\n');
  }

  summary() {
    const lines = [];
    lines.push('=== RÉSUMÉ STRATÉGIE ===');
    lines.push(`P1+P2: ${this.btc} WBTC collatéral + ${this.cash} USDT | Dette: ${this.debt} USDT`);

    if (this.btcAccum > 0) {
      const revente = +(this.btcAccum * this.ath).toFixed(0);
      const gain = revente - this.debt;
      lines.push(`P2 si retour ATH: vend ${this.btcAccum} BTC @ ${this.ath} = ${revente} — dette ${this.debt} = gain ${gain} USD (${(gain/this.ath).toFixed(4)} BTC)`);
    }

    const netPerp = this.gridProfit - this.fundingCost;
    lines.push(`P3 Grid: +${this.gridProfit.toFixed(0)} profit — ${this.fundingCost.toFixed(0)} funding = net ${netPerp.toFixed(0)} USD`);
    lines.push(`Total transactions: ${this.perpTxs} perp + ${this.onchainTxs} on-chain`);
    return lines.join('\n');
  }
}

module.exports = HedgeSimV2;

if (require.main === module) {
  const sim = new HedgeSimV2(+(process.argv[2] || 126000));
  console.log(sim.table() + '\n');
  const prices = process.argv.slice(3).map(Number).filter(Boolean);
  for (const p of prices) {
    console.log(`>>> ${p}`);
    sim.tick(p).forEach(l => console.log(l));
    console.log();
  }
  if (prices.length) console.log(sim.status());
}
