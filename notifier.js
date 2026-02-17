#!/usr/bin/env node
const https = require('https');
const TelegramBot = require('node-telegram-bot-api');
const { createCanvas } = require('canvas');
const Chart = require('chart.js/auto');

// === CONFIG ===
const BOT_TOKEN = 'REDACTED_BOT_TOKEN';
const CHAT_ID = 'REDACTED_CHAT_ID';
const POLL_INTERVAL = 60000; // 60s

// Strategy constants (matching server.js)
const ATH = 126000;
const WBTC_START = 3.90;
const STEP_SIZE = ATH * 0.05; // 6300
const BORROW_PER_STEP = WBTC_START * 3200; // 12480
const SHORT_PER_STEP = +(WBTC_START * 0.0244).toFixed(3); // 0.095

// Colors (matching dashboard)
const COLORS = {
  bg: '#121016',
  accent: '#f6b06b',
  green: '#6ee7a0', 
  red: '#f87171',
  purple: '#c4a6e8',
  blue: '#60a5fa',
  muted: '#7a7285'
};

// State tracking
let currentPrice = 0;
let currentStep = 0;
let priceHistory = [];
let lastNotificationStep = null;
let athTracked = ATH;

const bot = new TelegramBot(BOT_TOKEN, { polling: false });

// === UTILITIES ===
const fmt = (n) => n.toLocaleString('fr-FR');
const fmtUSD = (n) => '$' + fmt(Math.round(n));
const fmtBTC = (n, d=4) => n.toFixed(d) + ' BTC';

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

// === PRICE FETCHING ===
async function fetchCurrentPrice() {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'public/ticker',
      params: { instrument_name: 'BTC_USDC-PERPETUAL' }
    });

    const req = https.request({
      hostname: 'www.deribit.com',
      path: '/api/v2/public/ticker',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      }
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => body += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(body);
          if (parsed.error) {
            reject(new Error(parsed.error.message || JSON.stringify(parsed.error)));
          } else {
            resolve(parsed.result.last_price);
          }
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// === STEP & ZONE CALCULATIONS ===
function calculateCurrentStep(price) {
  // Count steps down from ATH
  let step = 0;
  const steps = Array.from({length: 19}, (_, i) => {
    const stepPrice = athTracked - (i+1) * STEP_SIZE;
    return { step: i+1, price: +stepPrice.toFixed(0) };
  });

  for (const s of steps) {
    if (price < s.price) step = s.step;
  }
  return step;
}

function getCurrentZone(price) {
  const pctFromATH = ((price - athTracked) / athTracked) * 100;
  
  if (pctFromATH > -12) return 'accumulation';
  else if (pctFromATH <= -12.3 && pctFromATH > -17.6) return 'zone1';
  else if (pctFromATH <= -17.6 && pctFromATH > -21) return 'zone2'; 
  else if (pctFromATH <= -21 && pctFromATH > -26) return 'stop';
  else return 'emergency';
}

function getZoneDetails(zone) {
  const zones = {
    accumulation: {
      emoji: '✅',
      name: 'Accumulation normale', 
      description: 'Au-dessus ATH −12%',
      actions: {
        auto: ['Continue grid trading normal', 'Borrow USDC selon paliers'],
        manual: []
      }
    },
    zone1: {
      emoji: '⚠️',
      name: 'Zone critique -12.3%',
      description: 'Vendre 50% puts + rembourser 25% dette',
      actions: {
        auto: ['Stop nouveaux emprunts temporairement'],
        manual: [
          '🔧 Vendre 50% des positions PUT sur Deribit',
          '💰 Rembourser 25% de la dette USDT sur AAVE',
          '📊 Réajuster allocation 79/18/3'
        ]
      }
    },
    zone2: {
      emoji: '🔶', 
      name: 'Zone critique -17.6%',
      description: 'Vendre puts restants + rembourser 40% dette',
      actions: {
        auto: ['Arrêt complet nouveaux emprunts'],
        manual: [
          '🔧 Vendre toutes les positions PUT restantes',
          '💰 Rembourser 40% de la dette USDT sur AAVE',
          '⚡ Réduire exposition futures/perpetuels'
        ]
      }
    },
    stop: {
      emoji: '🛑',
      name: 'STOP emprunts - Zone -21%', 
      description: 'Arrêt total emprunts',
      actions: {
        auto: ['STOP complet de tous les emprunts'],
        manual: [
          '🚫 Arrêter définitivement les emprunts AAVE',
          '⚡ Réduire fortement les shorts',
          '🔒 Mode préservation du capital'
        ]
      }
    },
    emergency: {
      emoji: '🚨',
      name: 'URGENCE - Zone -26%',
      description: 'Liquidation partielle d\'urgence',
      actions: {
        auto: ['LIQUIDATION PARTIELLE DÉCLENCHÉE'],
        manual: [
          '🚨 VENDRE IMMÉDIATEMENT toutes les positions PUT',
          '💸 Rembourser un maximum de dette USDT',
          '🆘 Considérer vente partielle WBTC si HF < 1.2',
          '📞 CONTACT IMMÉDIAT équipe risk management'
        ]
      }
    }
  };
  return zones[zone] || zones.accumulation;
}

// === SPARKLINE GENERATION ===
function generateSparkline(prices) {
  if (prices.length < 2) return '📊 —';
  
  const min = Math.min(...prices);
  const max = Math.max(...prices);
  const range = max - min;
  
  if (range === 0) return '📊 ━━━━━━━━';
  
  const chars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
  const sparkline = prices.slice(-8).map(price => {
    const normalized = (price - min) / range;
    const index = Math.min(Math.floor(normalized * chars.length), chars.length - 1);
    return chars[index];
  }).join('');
  
  const trend = prices[prices.length - 1] > prices[0] ? '📈' : '📉';
  return `${trend} ${sparkline}`;
}

// === CHART GENERATION ===
async function generateMiniChart(prices) {
  if (prices.length < 2) return null;
  
  try {
    const canvas = createCanvas(400, 150);
    const ctx = canvas.getContext('2d');
    
    // Create gradient background
    const gradient = ctx.createLinearGradient(0, 0, 0, 150);
    gradient.addColorStop(0, 'rgba(246, 176, 107, 0.3)');
    gradient.addColorStop(1, 'rgba(246, 176, 107, 0.05)');
    
    const chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: prices.map((_, i) => i),
        datasets: [{
          data: prices,
          borderColor: COLORS.accent,
          backgroundColor: gradient,
          borderWidth: 2,
          fill: true,
          tension: 0.2,
          pointRadius: 0
        }]
      },
      options: {
        responsive: false,
        plugins: {
          legend: { display: false },
          tooltip: { enabled: false }
        },
        scales: {
          x: { display: false },
          y: { 
            display: false,
            beginAtZero: false
          }
        },
        elements: {
          point: { radius: 0 }
        }
      }
    });
    
    return canvas.toBuffer('image/png');
  } catch (error) {
    log(`Chart generation failed: ${error.message}`);
    return null;
  }
}

// === NOTIFICATION BUILDER ===
function buildNotificationMessage(priceData, stepChange, zone) {
  const { price, step, direction, isNewATH } = priceData;
  const zoneInfo = getZoneDetails(zone);
  const pctFromATH = ((price - athTracked) / athTracked * 100).toFixed(2);
  
  let header = '';
  if (isNewATH) {
    header = `🚀 <b>NOUVEL ATH!</b> 🚀\n${fmtUSD(price)} (+${((price - athTracked) / athTracked * 100).toFixed(2)}%)`;
  } else {
    const stepLabel = direction === 'down' ? `Palier ${step} franchi ⬇️` : `Retour étape ${step} ⬆️`;
    header = `${zoneInfo.emoji} <b>${stepLabel}</b>\n💰 <b>${fmtUSD(price)}</b> (ATH ${pctFromATH}%)`;
  }

  const sparkline = generateSparkline(priceHistory.slice(-12));
  
  let autoActions = '';
  if (zoneInfo.actions.auto.length > 0) {
    autoActions = '\n⚡ <b>Actions AUTO:</b>\n';
    zoneInfo.actions.auto.forEach(action => {
      autoActions += `• ${action}\n`;
    });
  }

  let manualActions = '';  
  if (zoneInfo.actions.manual.length > 0) {
    manualActions = '\n🔧 <b>Actions MANUELLES:</b>\n';
    zoneInfo.actions.manual.forEach(action => {
      manualActions += `• ${action}\n`;
    });
  }

  const strategyInfo = `
📊 <b>Situation actuelle:</b>
• Zone: <b>${zoneInfo.name}</b>
• Step: ${step}/19 (${fmtUSD(STEP_SIZE)} par palier)
• Emprunt/palier: ${fmtUSD(BORROW_PER_STEP)}
• Short/palier: ${SHORT_PER_STEP} BTC
• ATH suivi: ${fmtUSD(athTracked)}

${sparkline}
`;

  return `${header}${strategyInfo}${autoActions}${manualActions}

💡 <i>Stratégie BTSAVE Hybrid - Répartition cible 79/18/3</i>`;
}

// === NOTIFICATION SENDING ===
async function sendNotification(message, chartBuffer = null) {
  try {
    const options = {
      chat_id: CHAT_ID,
      text: message,
      parse_mode: 'HTML',
      disable_web_page_preview: true
    };

    if (chartBuffer) {
      await bot.sendPhoto(CHAT_ID, chartBuffer, {
        caption: message,
        parse_mode: 'HTML'
      });
    } else {
      await bot.sendMessage(CHAT_ID, message, options);
    }
    
    log('Notification sent successfully');
  } catch (error) {
    log(`Failed to send notification: ${error.message}`);
  }
}

// === STEP DETECTION & NOTIFICATION ===
async function checkPriceAndNotify() {
  try {
    const price = await fetchCurrentPrice();
    currentPrice = price;
    priceHistory.push(price);
    
    // Keep history manageable
    if (priceHistory.length > 100) {
      priceHistory = priceHistory.slice(-50);
    }
    
    const step = calculateCurrentStep(price);
    const zone = getCurrentZone(price);
    
    // Check for new ATH
    if (price > athTracked) {
      athTracked = price;
      const message = buildNotificationMessage({
        price,
        step: 0,
        direction: 'up',
        isNewATH: true
      }, null, 'accumulation');
      
      const chartBuffer = await generateMiniChart(priceHistory.slice(-24));
      await sendNotification(message, chartBuffer);
      
      lastNotificationStep = 0;
      currentStep = 0;
      log(`New ATH detected: ${fmtUSD(price)}`);
      return;
    }
    
    // Check for step change
    if (step !== currentStep && (lastNotificationStep === null || step !== lastNotificationStep)) {
      const direction = step > currentStep ? 'down' : 'up';
      const message = buildNotificationMessage({
        price,
        step,
        direction,
        isNewATH: false
      }, { from: currentStep, to: step }, zone);
      
      const chartBuffer = await generateMiniChart(priceHistory.slice(-24));
      await sendNotification(message, chartBuffer);
      
      lastNotificationStep = step;
      currentStep = step;
      log(`Step change detected: ${currentStep} -> ${step} (${direction})`);
    }
    
    log(`Price: ${fmtUSD(price)} | Step: ${step} | Zone: ${zone}`);
    
  } catch (error) {
    log(`Error in price check: ${error.message}`);
  }
}

// === TEST NOTIFICATIONS ===
async function sendTestNotification(scenario) {
  let testData, testZone;
  
  switch (scenario) {
    case 'step_down':
      testData = {
        price: 113400, // Step 2
        step: 2,
        direction: 'down',
        isNewATH: false
      };
      testZone = 'accumulation';
      // Simulate price history
      priceHistory = [126000, 125000, 120000, 118000, 115000, 113500, 113400];
      break;
      
    case 'critical_zone':
      testData = {
        price: 110484, // -12.3%
        step: 3,
        direction: 'down', 
        isNewATH: false
      };
      testZone = 'zone1';
      priceHistory = [126000, 123000, 118000, 115000, 112000, 110800, 110484];
      break;
      
    case 'new_ath':
      testData = {
        price: 128500,
        step: 0,
        direction: 'up',
        isNewATH: true
      };
      testZone = 'accumulation';
      priceHistory = [126000, 126200, 126800, 127200, 127800, 128200, 128500];
      athTracked = 128500;
      break;
      
    default:
      throw new Error('Unknown test scenario');
  }
  
  const message = buildNotificationMessage(testData, null, testZone);
  const chartBuffer = await generateMiniChart(priceHistory.slice(-12));
  
  await sendNotification(`🧪 <b>[TEST]</b> ${message}`, chartBuffer);
  log(`Test notification sent: ${scenario}`);
}

// === MAIN LOOP ===
async function startMonitoring() {
  log('🚀 BTSAVE Price Notifier started');
  log(`Monitoring BTC_USDC-PERPETUAL every ${POLL_INTERVAL/1000}s`);
  log(`ATH tracked: ${fmtUSD(athTracked)}`);
  log(`Step size: ${fmtUSD(STEP_SIZE)}`);
  
  // Initial price fetch
  await checkPriceAndNotify();
  
  // Start polling
  setInterval(checkPriceAndNotify, POLL_INTERVAL);
}

// === GRACEFUL SHUTDOWN ===
process.on('SIGTERM', () => {
  log('Received SIGTERM, shutting down gracefully');
  process.exit(0);
});

process.on('SIGINT', () => {
  log('Received SIGINT, shutting down gracefully');
  process.exit(0);
});

// Export for testing
if (require.main === module) {
  startMonitoring().catch(error => {
    log(`Failed to start monitoring: ${error.message}`);
    process.exit(1);
  });
} else {
  module.exports = { sendTestNotification };
}