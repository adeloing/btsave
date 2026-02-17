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

// === DASHBOARD SCREENSHOT ===
async function captureChartScreenshot() {
  try {
    await initBrowser();
    const page = await browser.newPage();
    
    // Navigate to dashboard
    await page.goto(DASHBOARD_URL, { waitUntil: 'networkidle2' });
    
    // Login (check if we're redirected to login page)
    const currentUrl = page.url();
    if (currentUrl.includes('login.html') || currentUrl.includes('login')) {
      log('Login required, authenticating...');
      
      await page.waitForSelector('input[name="username"]', { timeout: 10000 });
      await page.type('input[name="username"]', 'xou');
      await page.type('input[name="password"]', '682011sac');
      await page.click('button[type="submit"]');
      
      // Wait for redirect and navigation
      await page.waitForNavigation({ waitUntil: 'networkidle2' });
    }
    
    // Navigate to the main dashboard (served from root)
    if (page.url().includes('login.html')) {
      await page.goto(DASHBOARD_URL + '/', { waitUntil: 'networkidle2' });
    }
    
    // Wait for chart to load
    await page.waitForSelector('.chart-wrap canvas', { timeout: 15000 });
    
    // Wait a bit more for chart animation to complete using standard setTimeout
    await new Promise(resolve => setTimeout(resolve, 3000));
    
    // Capture just the chart area
    const chartElement = await page.$('.chart-wrap');
    if (!chartElement) {
      throw new Error('Chart element not found');
    }
    
    const chartScreenshot = await chartElement.screenshot({
      type: 'png',
      quality: 90
    });
    
    await page.close();
    return chartScreenshot;
    
  } catch (error) {
    log(`Screenshot capture failed: ${error.message}`);
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
  const pctFromATH = ((price - athTracked) / athTracked) * 100;
  
  if (pctFromATH > -12.3) return 'accumulation';
  else if (pctFromATH <= -12.3 && pctFromATH > -17.6) return 'zone1';
  else if (pctFromATH <= -17.6 && pctFromATH > -21) return 'zone2'; 
  else if (pctFromATH <= -21 && pctFromATH > -26) return 'stop';
  else return 'emergency';
}

// === NOTIFICATION FORMATTING ===
function buildStepNotification(price, step, direction, zone) {
  const pctFromATH = ((price - athTracked) / athTracked * 100).toFixed(2);
  
  let header, zoneSection, actions;
  
  // Header
  const stepText = direction === 'down' ? `↘️ PALIER ${step} FRANCHI` : `↗️ REMONTÉE PALIER ${step}`;
  header = `━━━━━━━━━━━━━━━━━━━━\n${stepText}\n━━━━━━━━━━━━━━━━━━━━\n\n💰 Prix: ${fmtUSD(price)}\n📉 ATH: ${pctFromATH}% (${fmtUSD(athTracked)})\n📊 Step: ${step}/19`;
  
  // Zone-specific content
  switch(zone) {
    case 'accumulation':
      zoneSection = '\n━━━ 🟢 ACCUMULATION ━━━';
      actions = '\n⚡ ACTIONS AUTO:\n▸ Deribit: Stop Market SELL ' + SHORT_PER_STEP + ' BTC déclenché\n▸ Funding/contango: accrual normal\n\n🔧 ACTIONS MANUELLES:\n▸ AAVE: Borrow ' + fmt(BORROW_PER_STEP) + ' USDC\n▸ DeFiLlama: Swap USDC → WBTC\n▸ Déposer aEthWBTC sur AAVE';
      break;
      
    case 'zone1':
      zoneSection = '\n━━━ 🟡 ZONE1 (-12.3%) ━━━';
      actions = '\n⚡ ACTIONS AUTO:\n▸ Deribit: Stop nouveaux shorts\n▸ AAVE: Pause nouveaux emprunts\n\n🔧 ACTIONS MANUELLES:\n▸ Vendre 50% des PUT Deribit\n▸ Rembourser 25% dette AAVE\n▸ Réduire exposition leverage';
      break;
      
    case 'zone2':
      zoneSection = '\n━━━ 🟠 ZONE2 (-17.6%) ━━━';
      actions = '\n⚡ ACTIONS AUTO:\n▸ Stop complet nouveaux positions\n▸ Alerte risque élevé\n\n🔧 ACTIONS MANUELLES:\n▸ Vendre PUT restants\n▸ Rembourser 40% dette restante\n▸ Préparer liquidation partielle';
      break;
      
    case 'stop':
      zoneSection = '\n━━━ 🔴 STOP (-21%) ━━━';
      actions = '\n⚡ ACTIONS AUTO:\n▸ ⛔ STOP tous les emprunts\n▸ 🚨 Mode survie activé\n\n🔧 ACTIONS MANUELLES:\n▸ ⛔ STOP tous les emprunts\n▸ Fermer positions risquées\n▸ Préserver capital restant';
      break;
      
    case 'emergency':
      zoneSection = '\n━━━ ⛔ EMERGENCY (-26%) ━━━';
      actions = '\n⚡ ACTIONS AUTO:\n▸ 🚨 LIQUIDATION PARTIELLE\n▸ 📞 ALERTE ÉQUIPE\n\n🔧 ACTIONS MANUELLES:\n▸ 🚨 VENDRE TOUS les PUT\n▸ 🚨 Rembourser maximum dette\n▸ 🆘 Contact équipe risk management';
      break;
  }
  
  const footer = '\n━━━━━━━━━━━━━━━━━━━━\nBTSAVE Hybrid 79/18/3\n━━━━━━━━━━━━━━━━━━━━';
  
  return header + zoneSection + actions + footer;
}

function buildATHNotification(newPrice, oldATH) {
  const pctGain = ((newPrice - oldATH) / oldATH * 100).toFixed(2);
  
  return `━━━━━━━━━━━━━━━━━━━━\n🚀 NOUVEL ATH ATTEINT!\n━━━━━━━━━━━━━━━━━━━━\n\n💰 Prix: ${fmtUSD(newPrice)} (+${pctGain}%)\n🎯 Ancien ATH: ${fmtUSD(oldATH)}\n\n━━━ RESET DU CYCLE ━━━\n\n🔧 ACTIONS DE RESET:\n▸ Fermer TOUS les shorts Deribit\n▸ Rembourser 100% dette AAVE\n▸ Conserver tout WBTC accumulé\n▸ Rééquilibrer: 79% WBTC / 18% USDC AAVE / 3% USDC Deribit\n▸ Recalculer tous les paliers\n\n━━━━━━━━━━━━━━━━━━━━`;
}

// === NOTIFICATION SENDING ===
async function sendNotification(message, screenshotBuffer = null) {
  try {
    if (screenshotBuffer) {
      // Send photo first with short caption (header only)
      const shortCaption = message.split('\n\n')[0] + '\n' + message.split('\n\n')[1];
      
      await bot.sendPhoto(CHAT_ID, screenshotBuffer, {
        caption: shortCaption,
        parse_mode: 'HTML'
      });
      
      // Then send full text message
      await bot.sendMessage(CHAT_ID, message, {
        parse_mode: 'HTML',
        disable_web_page_preview: true
      });
    } else {
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
      
      const message = buildATHNotification(price, oldATH);
      const screenshot = await captureChartScreenshot();
      
      await sendNotification(message, screenshot);
      
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
      const message = buildStepNotification(price, step, direction, zone);
      const screenshot = await captureChartScreenshot();
      
      await sendNotification(message, screenshot);
      
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
      name: 'Zone1 - Critical (-12.3%)',
      price: 110502,
      step: 3,
      direction: 'down',
      zone: 'zone1'
    },
    {
      name: 'Zone2 - Danger (-17.6%)',
      price: 103824,
      step: 5,
      direction: 'down',
      zone: 'zone2'
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
    
    let message;
    if (scenario.isATH) {
      message = `🧪 [TEST ${i+1}/5]\n\n` + buildATHNotification(scenario.price, athTracked);
    } else {
      message = `🧪 [TEST ${i+1}/5]\n\n` + buildStepNotification(scenario.price, scenario.step, scenario.direction, scenario.zone);
    }
    
    // Capture screenshot for each test
    const screenshot = await captureChartScreenshot();
    await sendNotification(message, screenshot);
    
    // Wait 2 seconds between messages to avoid rate limits
    if (i < scenarios.length - 1) {
      await new Promise(resolve => setTimeout(resolve, 2000));
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