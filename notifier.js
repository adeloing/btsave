#!/usr/bin/env node
const https = require('https');
const TelegramBot = require('node-telegram-bot-api');
const puppeteer = require('puppeteer');
const fs = require('fs').promises;

// === CONFIG ===
const BOT_TOKEN = '8515726191:AAHKbVuCTL304hiiQlapfVGxWfT4ASvYxZQ';
const CHAT_ID = '7021342074';
const POLL_INTERVAL = 30000; // 30s as requested
const DASHBOARD_URL = 'http://localhost:3001';

// Strategy constants (matching server.js)
const ATH = 126000;
const WBTC_START = 3.90;
const STEP_SIZE = ATH * 0.05; // 6300
const BORROW_PER_STEP = WBTC_START * 3200; // 12480
const SHORT_PER_STEP = +(WBTC_START * 0.0244).toFixed(3); // 0.095

// State tracking
let currentPrice = 0;
let currentStep = 0;
let currentZone = 'accumulation';
let lastNotificationStep = null;
let lastNotificationZone = null;
let athTracked = ATH;
let browser = null;

const bot = new TelegramBot(BOT_TOKEN, { polling: false });

// === UTILITIES ===
const fmt = (n) => n.toLocaleString('fr-FR');
const fmtUSD = (n) => '$' + fmt(Math.round(n));
const fmtBTC = (n, d=4) => n.toFixed(d) + ' BTC';

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

// === BROWSER MANAGEMENT ===
async function initBrowser() {
  if (browser) return browser;
  
  browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
    defaultViewport: { width: 1200, height: 800 }
  });
  
  log('Browser initialized');
  return browser;
}

async function closeBrowser() {
  if (browser) {
    await browser.close();
    browser = null;
    log('Browser closed');
  }
}

// === DERIBIT CHART DATA ===
async function fetchDeribitChartData() {
  return new Promise((resolve, reject) => {
    // Get data for last 24h with 15min resolution
    const endTime = Math.floor(Date.now() / 1000) * 1000; // Current timestamp in ms
    const startTime = endTime - (24 * 60 * 60 * 1000); // 24h ago in ms

    const params = new URLSearchParams({
      instrument_name: 'BTC_USDC-PERPETUAL',
      start_timestamp: startTime.toString(),
      end_timestamp: endTime.toString(),
      resolution: '15'
    });

    const req = https.request({
      hostname: 'www.deribit.com',
      path: `/api/v2/public/get_tradingview_chart_data?${params}`,
      method: 'GET',
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
            resolve(parsed.result);
          }
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on('error', reject);
    req.end();
  });
}

// === HTML NOTIFICATION IMAGE GENERATION ===
async function generateNotificationImage(data) {
  try {
    await initBrowser();
    const page = await browser.newPage();
    await page.setViewport({ width: 480, height: 800 });

    // Fetch chart data
    const chartData = await fetchDeribitChartData();
    
    // Prepare chart data for Chart.js
    const chartLabels = chartData.ticks.map((tick, i) => i); // Just indices for clean x-axis
    const chartPrices = chartData.close;
    
    // Calculate zoomed Y-axis range (±5% from the step price)
    const stepPrice = data.price;
    const yMin = stepPrice * 0.95;
    const yMax = stepPrice * 1.05;

    const htmlContent = `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=480, initial-scale=1.0">
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #121016;
            color: #e8e4ed;
            width: 480px;
            min-height: 600px;
            padding: 20px;
        }
        
        .header {
            text-align: center;
            margin-bottom: 20px;
        }
        .header h1 {
            color: #f6b06b;
            font-size: 20px;
            font-weight: bold;
            margin-bottom: 8px;
        }
        .header .price-info {
            color: #e8e4ed;
            font-size: 16px;
            line-height: 1.4;
        }
        
        .chart-container {
            background: #1a171f;
            border-radius: 12px;
            padding: 16px;
            margin: 20px 0;
            height: 280px;
        }
        
        .badge {
            text-align: center;
            padding: 12px;
            border-radius: 8px;
            font-weight: bold;
            font-size: 16px;
            margin: 20px 0;
        }
        .badge.accumulation { background: #22c55e; color: #000; }
        .badge.zone1 { background: #eab308; color: #000; }
        .badge.zone2 { background: #f97316; color: #000; }
        .badge.stop { background: #ef4444; color: #fff; }
        .badge.emergency { background: #991b1b; color: #fff; }
        
        .actions {
            margin: 16px 0;
        }
        .actions-header {
            font-size: 16px;
            font-weight: bold;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
        }
        .actions-header.auto { color: #6ee7a0; }
        .actions-header.manual { color: #60a5fa; }
        .actions-content {
            font-size: 14px;
            line-height: 1.6;
            margin-left: 4px;
        }
        
        .footer {
            text-align: center;
            color: #7a7285;
            font-size: 14px;
            margin-top: 20px;
            padding-top: 16px;
            border-top: 1px solid #2a2630;
        }
        
        #chart { width: 100%; height: 220px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>${data.direction === 'down' ? '↘️' : '↗️'} ${data.isATH ? 'NOUVEL ATH' : `PALIER ${data.step} FRANCHI`}</h1>
        <div class="price-info">
            ${fmtUSD(data.price)}${data.isATH ? '' : ` · ATH ${data.pctFromATH}%`}
        </div>
    </div>
    
    <div class="chart-container">
        <canvas id="chart"></canvas>
    </div>
    
    <div class="badge ${data.zone}">
        ${data.zoneDisplay}
    </div>
    
    <div class="actions">
        <div class="actions-header auto">⚡ Auto</div>
        <div class="actions-content">${data.autoActions}</div>
    </div>
    
    <div class="actions">
        <div class="actions-header manual">🔧 Manuel</div>
        <div class="actions-content">${data.manualActions}</div>
    </div>
    
    <div class="footer">
        BTSAVE Hybrid · 79/18/3
    </div>

    <script>
        const ctx = document.getElementById('chart').getContext('2d');
        const chartData = {
            labels: ${JSON.stringify(chartLabels)},
            datasets: [{
                label: 'BTC Price',
                data: ${JSON.stringify(chartPrices)},
                borderColor: '#f6b06b',
                backgroundColor: function(context) {
                    const chart = context.chart;
                    const {ctx, chartArea} = chart;
                    if (!chartArea) return null;
                    
                    const gradient = ctx.createLinearGradient(0, chartArea.top, 0, chartArea.bottom);
                    gradient.addColorStop(0, 'rgba(246, 176, 107, 0.3)');
                    gradient.addColorStop(1, 'rgba(246, 176, 107, 0.05)');
                    return gradient;
                },
                borderWidth: 2,
                fill: true,
                tension: 0.1,
                pointRadius: 0,
                pointHoverRadius: 0
            }]
        };
        
        new Chart(ctx, {
            type: 'line',
            data: chartData,
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { display: false },
                    tooltip: { enabled: false }
                },
                scales: {
                    x: {
                        display: false
                    },
                    y: {
                        min: ${yMin},
                        max: ${yMax},
                        display: true,
                        grid: {
                            color: '#2a2630',
                            drawBorder: false
                        },
                        ticks: {
                            color: '#7a7285',
                            font: { size: 12 }
                        }
                    }
                },
                animation: false,
                elements: {
                    line: {
                        borderWidth: 2
                    }
                }
            },
            plugins: [{
                afterDraw: function(chart) {
                    const ctx = chart.ctx;
                    const chartArea = chart.chartArea;
                    
                    // Draw horizontal line at step price
                    const yPosition = chart.scales.y.getPixelForValue(${stepPrice});
                    
                    ctx.save();
                    ctx.strokeStyle = '#ffffff';
                    ctx.lineWidth = 2;
                    ctx.setLineDash([8, 4]);
                    ctx.beginPath();
                    ctx.moveTo(chartArea.left, yPosition);
                    ctx.lineTo(chartArea.right, yPosition);
                    ctx.stroke();
                    ctx.restore();
                }
            }]
        });
        
        // Signal that chart is ready
        window.chartReady = true;
    </script>
</body>
</html>`;

    await page.setContent(htmlContent);
    
    // Wait for chart to render
    await page.waitForFunction(() => window.chartReady, { timeout: 10000 });
    await new Promise(resolve => setTimeout(resolve, 1000));

    // Take screenshot of entire page
    const screenshot = await page.screenshot({
      type: 'png',
      fullPage: true
    });

    await page.close();
    return screenshot;

  } catch (error) {
    log(`HTML notification image generation failed: ${error.message}`);
    return null;
  }
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
  // Finale Ultime: zones are HF-based, but notifier uses price as proxy
  // since we don't have real-time HF here. Zone mapping is approximate.
  // Real HF-based decisions are made on the dashboard/manual level.
  // For notification purposes, we just track step crossings.
  return 'accumulation'; // All steps are accumulation — HF governs actions, not price
}

// === NOTIFICATION DATA PREPARATION ===
function buildStepNotificationData(price, step, direction, zone) {
  const pctFromATH = ((price - athTracked) / athTracked * 100).toFixed(2);
  
  let zoneDisplay, autoActions, manualActions;
  
  // Finale Ultime: all steps are accumulation (HF governs actions, not price)
  zoneDisplay = '🟢 ACCUMULATION';
  autoActions = '· Stop Market SELL ' + SHORT_PER_STEP + ' BTC\n· Funding accrual normal';
  manualActions = '· Borrow ' + fmt(BORROW_PER_STEP) + ' USDC AAVE\n· DeFiLlama swap → WBTC\n· Déposer aEthWBTC\n· Vérifier Health Factor AAVE';
  
  return {
    price,
    step,
    direction,
    zone,
    pctFromATH,
    zoneDisplay,
    autoActions,
    manualActions,
    isATH: false
  };
}

function buildATHNotificationData(newPrice, oldATH) {
  const pctGain = ((newPrice - oldATH) / oldATH * 100).toFixed(2);
  
  return {
    price: newPrice,
    step: 0,
    direction: 'up',
    zone: 'accumulation',
    pctFromATH: `+${pctGain}`,
    zoneDisplay: '🚀 RESET DU CYCLE',
    autoActions: '· Fermer TOUS les shorts\n· Reset paliers automatique',
    manualActions: '· Rembourser 100% dette AAVE\n· Rééquilibrer 79/18/3\n· Recalculer paliers',
    isATH: true
  };
}

// Helper function to generate caption for Telegram
function generateCaption(data) {
  const prefix = data.testPrefix || '';
  
  if (data.isATH) {
    return `${prefix}🚀 Nouvel ATH · ${fmtUSD(data.price)} · 🚀 Reset`;
  } else {
    const direction = data.direction === 'down' ? '↘️' : '↗️';
    return `${prefix}${direction} Palier ${data.step} · ${fmtUSD(data.price)} · ${data.zoneDisplay}`;
  }
}

// === NOTIFICATION SENDING ===
async function sendNotification(data) {
  try {
    // Generate HTML notification image
    const notificationImage = await generateNotificationImage(data);
    
    if (notificationImage) {
      // Send single image with caption
      const caption = generateCaption(data);
      
      await bot.sendPhoto(CHAT_ID, notificationImage, {
        caption: caption,
        parse_mode: 'HTML'
      });
    } else {
      // Fallback to text-only message if image generation fails
      const message = data.isATH 
        ? `🚀 NOUVEL ATH: ${fmtUSD(data.price)}`
        : `${data.direction === 'down' ? '↘️' : '↗️'} PALIER ${data.step}: ${fmtUSD(data.price)} · ${data.zoneDisplay}`;
      
      await bot.sendMessage(CHAT_ID, message, {
        parse_mode: 'HTML',
        disable_web_page_preview: true
      });
    }
    
    log('Notification sent successfully');
  } catch (error) {
    log(`Failed to send notification: ${error.message}`);
  }
}

// === MONITORING LOGIC ===
async function checkPriceAndNotify() {
  try {
    const price = await fetchCurrentPrice();
    currentPrice = price;
    
    const step = calculateCurrentStep(price);
    const zone = getCurrentZone(price);
    
    // Check for new ATH
    if (price > athTracked) {
      const oldATH = athTracked;
      athTracked = price;
      
      const notificationData = buildATHNotificationData(price, oldATH);
      await sendNotification(notificationData);
      
      lastNotificationStep = 0;
      lastNotificationZone = 'accumulation';
      currentStep = 0;
      currentZone = 'accumulation';
      
      log(`New ATH detected: ${fmtUSD(price)}`);
      return;
    }
    
    // Check for step change OR zone change
    const stepChanged = step !== currentStep && (lastNotificationStep === null || step !== lastNotificationStep);
    const zoneChanged = zone !== currentZone && (lastNotificationZone === null || zone !== lastNotificationZone);
    
    if (stepChanged || zoneChanged) {
      const direction = step > currentStep ? 'down' : 'up';
      const notificationData = buildStepNotificationData(price, step, direction, zone);
      await sendNotification(notificationData);
      
      lastNotificationStep = step;
      lastNotificationZone = zone;
      currentStep = step;
      currentZone = zone;
      
      log(`Change detected - Step: ${currentStep} -> ${step}, Zone: ${currentZone} -> ${zone}`);
    }
    
    // Update current state
    currentStep = step;
    currentZone = zone;
    
    log(`Price: ${fmtUSD(price)} | Step: ${step} | Zone: ${zone}`);
    
  } catch (error) {
    log(`Error in price check: ${error.message}`);
  }
}

// === TEST NOTIFICATIONS ===
async function sendTestNotifications() {
  log('📢 Sending 5 test notifications...');
  
  const scenarios = [
    {
      name: 'Step 2 - Accumulation',
      price: 113400,
      step: 2,
      direction: 'down',
      zone: 'accumulation'
    },
    {
      name: 'Step 3 - Accumulation (HF check)',
      price: 107100,
      step: 3,
      direction: 'down',
      zone: 'accumulation'
    },
    {
      name: 'Step 5 - Deep Accumulation',
      price: 94500,
      step: 5,
      direction: 'down',
      zone: 'accumulation'
    },
    {
      name: 'Recovery - Step 1',
      price: 119700,
      step: 1,
      direction: 'up',
      zone: 'accumulation'
    },
    {
      name: 'New ATH Reset',
      price: 128000,
      isATH: true
    }
  ];
  
  for (let i = 0; i < scenarios.length; i++) {
    const scenario = scenarios[i];
    log(`📤 Sending test ${i+1}/5: ${scenario.name}`);
    
    let notificationData;
    if (scenario.isATH) {
      notificationData = buildATHNotificationData(scenario.price, athTracked);
    } else {
      notificationData = buildStepNotificationData(scenario.price, scenario.step, scenario.direction, scenario.zone);
    }
    
    // Add test prefix to caption
    const originalCaption = generateCaption(notificationData);
    notificationData.testPrefix = `🧪 [TEST ${i+1}/5] `;
    
    await sendNotification(notificationData);
    
    // Wait 3 seconds between messages to avoid rate limits and allow chart rendering
    if (i < scenarios.length - 1) {
      await new Promise(resolve => setTimeout(resolve, 3000));
    }
  }
  
  log('✅ All test notifications sent!');
}

// === MAIN LOOP ===
async function startMonitoring() {
  log('🚀 BTSAVE Price Notifier v2 started');
  log(`Monitoring BTC_USDC-PERPETUAL every ${POLL_INTERVAL/1000}s`);
  log(`ATH tracked: ${fmtUSD(athTracked)}`);
  log(`Dashboard: ${DASHBOARD_URL}`);
  
  // Initial setup
  await initBrowser();
  
  // Initial price fetch
  await checkPriceAndNotify();
  
  // Start polling
  setInterval(checkPriceAndNotify, POLL_INTERVAL);
}

// === GRACEFUL SHUTDOWN ===
async function shutdown() {
  log('Shutting down gracefully...');
  await closeBrowser();
  process.exit(0);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
process.on('uncaughtException', (error) => {
  log(`Uncaught exception: ${error.message}`);
  shutdown();
});

// === ENTRY POINT ===
if (require.main === module) {
  // Check for test argument
  if (process.argv[2] === 'test') {
    sendTestNotifications().then(() => {
      setTimeout(shutdown, 5000); // Allow time for final messages
    }).catch(error => {
      log(`Test failed: ${error.message}`);
      shutdown();
    });
  } else {
    startMonitoring().catch(error => {
      log(`Failed to start monitoring: ${error.message}`);
      shutdown();
    });
  }
} else {
  module.exports = { sendTestNotifications };
}