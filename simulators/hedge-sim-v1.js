// Hedge Simulator — Kei ⚡

// --- Black-Scholes pricing ---
function normCDF(x) {
  const a = 0.2316419, b1 = 0.319381530, b2 = -0.356563782;
  const b3 = 1.781477937, b4 = -1.821255978, b5 = 1.330274429;
  const t = 1 / (1 + a * Math.abs(x));
  const pdf = Math.exp(-x * x / 2) / Math.sqrt(2 * Math.PI);
  const cdf = 1 - pdf * (b1*t + b2*t**2 + b3*t**3 + b4*t**4 + b5*t**5);
  return x >= 0 ? cdf : 1 - cdf;
}

function bsPrice(type, spot, strike, iv = 0.6, dte = 30) {
  const T = dte / 365;
  const d1 = (Math.log(spot / strike) + (iv**2 / 2) * T) / (iv * Math.sqrt(T));
  const d2 = d1 - iv * Math.sqrt(T);
  if (type === 'CALL') return spot * normCDF(d1) - strike * normCDF(d2);
  return strike * normCDF(-d2) - spot * normCDF(-d1);
}

class HedgeSimulator {
  constructor(ath, { totalBtc = 1, iv = 0.6, dte = 30, contractSize = 0.1 } = {}) {
    this.totalBtc = totalBtc;
    this.iv = iv;
    this.dte = dte;
    this.contractSize = contractSize;
    this.positions = [];
    this.totalCost = 0;
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

  callStrike(s) { return s === 1 ? this.ath : this.r(s - 1).lo; }
  putStrike(s, dir) {
    if (s >= 19) return null;
    return dir === 'up' ? this.r(s + 1).hi : this.r(s + 1).lo;
  }

  buy(type, strike, step, reason, spot) {
    const premium = bsPrice(type, spot, strike, this.iv, this.dte);
    const cost = +(premium * this.contractSize).toFixed(2);
    this.totalCost += cost;
    this.positions.push({ type, strike, step, reason, spot, cost });
    const icon = type === 'CALL' ? '📈' : '📉';
    return `  ${icon} BUY ${type} strike=${strike} | coût: ${cost} USD`;
  }

  hedge(s, dir, prix, out) {
    out.push(this.buy('CALL', this.callStrike(s), s, dir, prix));
    const ps = this.putStrike(s, dir);
    if (ps) out.push(this.buy('PUT', ps, s, dir, prix));
    this.lastActivated = s;
  }

  tick(prix) {
    const out = [];

    // New ATH check
    const rounded = Math.floor(prix / 1000) * 1000;
    if (rounded >= this.ath + 1000) {
      out.push(`🔺 NOUVEL ATH! ${rounded} (ancien: ${this.ath})`);
      this.setATH(rounded);
      return out;
    }

    // Back above ATH
    if (prix >= this.ath && this.lastStep > 0) {
      out.push(`🏔️ Retour au-dessus de l'ATH (${this.ath})`);
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
          ref.first = true;
          this.lastActivated = s;
          if (s === 1) {
            out.push(`⚠️ Palier 1 franchi — prix: ${prix} — NOTIF`);
          } else {
            out.push(`⚠️ Palier ${s} franchi — prix: ${prix}`);
            out.push(this.buy('CALL', this.callStrike(s), s, '1st_down', prix));
            this.lastActivated = s;
          }
        } else {
          out.push(`↘️ Retour palier ${s} — prix: ${prix}`);
          this.hedge(s, 'down', prix, out);
        }
      }
      this.lastStep = target;
    }

    // Going UP
    if (target < this.lastStep) {
      for (let s = this.lastStep; s > target; s--) {
        if (s === skip) { out.push(`⏭️ Skip palier ${s}`); continue; }
        out.push(`↗️ ${s === 1 ? 'Traverse' : 'Quitte'} palier ${s} — prix: ${prix}`);
        this.hedge(s, 'up', prix, out);
      }
      this.lastStep = target;
    }

    return out;
  }

  settle(prix) {
    if (!this.positions.length) return ['Aucune position à solder.'];
    const out = ['📊 LIQUIDATION — prix spot: ' + prix];
    let totalVal = 0;
    for (const p of this.positions) {
      const val = p.type === 'CALL' ? Math.max(0, prix - p.strike) : Math.max(0, p.strike - prix);
      const payoff = +(val * this.contractSize).toFixed(2);
      totalVal += payoff;
      const itm = val > 0 ? '✅ ITM' : '❌ OTM';
      out.push(`  ${p.type} ${p.strike} (step ${p.step}) → ${itm} | payoff: ${payoff} | coût: ${p.cost}`);
    }
    const pnl = +(totalVal - this.totalCost).toFixed(2);
    out.push('');
    out.push(`💸 Coût total primes: ${this.totalCost.toFixed(2)} USD`);
    out.push(`💰 Payoff total: ${totalVal.toFixed(2)} USD`);
    out.push(`${pnl >= 0 ? '🟢' : '🔴'} P&L net: ${pnl >= 0 ? '+' : ''}${pnl} USD`);
    out.push(`📦 ${this.positions.length} positions soldées`);
    this.positions = [];
    this.totalCost = 0;
    return out;
  }

  status() {
    const lines = [`ATH: ${this.ath} | Palier: ${this.lastStep} | Positions: ${this.positions.length} | Coût: ${this.totalCost.toFixed(2)} USD`];
    this.positions.forEach(p => lines.push(`  ${p.type} ${p.strike} (step ${p.step}, ${p.reason}) coût: ${p.cost}`));
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
}

module.exports = HedgeSimulator;

if (require.main === module) {
  const sim = new HedgeSimulator(+(process.argv[2] || 126000));
  console.log(sim.table() + '\n');
  const prices = process.argv.slice(3).map(Number).filter(Boolean);
  for (const p of prices) {
    console.log(`>>> ${p}`);
    sim.tick(p).forEach(l => console.log(l));
  }
  if (prices.length) console.log('\n' + sim.status());
}
