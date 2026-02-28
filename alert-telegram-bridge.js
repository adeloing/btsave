/**
 * Alertmanager → Telegram Bridge
 * Receives Prometheus Alertmanager webhooks and forwards to Telegram.
 */
const http = require('http');
const https = require('https');

const BOT_TOKEN = 'REDACTED_BOT_TOKEN';
const CHAT_ID = 'REDACTED_CHAT_ID';
const PORT = 9102;

function sendTelegram(text) {
  const body = JSON.stringify({
    chat_id: CHAT_ID,
    text,
    parse_mode: 'HTML',
    disable_web_page_preview: true
  });
  const req = https.request({
    hostname: 'api.telegram.org',
    path: `/bot${BOT_TOKEN}/sendMessage`,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
  });
  req.on('error', e => console.error('Telegram error:', e.message));
  req.write(body);
  req.end();
}

function formatAlert(alert) {
  const status = alert.status === 'firing' ? '🚨' : '✅';
  const name = alert.labels?.alertname || 'Unknown';
  const severity = alert.labels?.severity || 'info';
  const summary = alert.annotations?.summary || '';
  const description = alert.annotations?.description || '';
  
  let icon = '📊';
  if (severity === 'critical') icon = '🔴';
  else if (severity === 'warning') icon = '🟡';
  else if (severity === 'info') icon = '🔵';
  
  const tag = alert.status === 'firing' ? 'ALERT' : 'RESOLVED';
  
  let msg = `${status} <b>[${tag}] ${icon} ${name}</b>\n`;
  if (summary) msg += `${summary}\n`;
  if (description) msg += `<i>${description}</i>\n`;
  msg += `Severity: ${severity}`;
  
  return msg;
}

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/alert') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const alerts = data.alerts || [];
        for (const alert of alerts) {
          const msg = formatAlert(alert);
          sendTelegram(msg);
          console.log(`[${new Date().toISOString()}] Sent: ${alert.labels?.alertname} (${alert.status})`);
        }
        res.writeHead(200);
        res.end('ok');
      } catch (e) {
        console.error('Parse error:', e.message);
        res.writeHead(400);
        res.end('bad request');
      }
    });
  } else {
    res.writeHead(200);
    res.end('alert-telegram-bridge alive');
  }
});

server.listen(PORT, () => {
  console.log(`🔔 Alert→Telegram bridge on :${PORT}`);
});
