#!/bin/bash
# btsave Deployment Script

set -e

APP_DIR="/opt/btsave"
SOURCE_DIR="/root/.openclaw/workspace/btsave"

echo "🚀 Starting deployment..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root"
  exit 1
fi

# Stop existing service
echo "⏹️  Stopping existing service..."
systemctl stop btsave 2>/dev/null || true

# Create app user if not exists
if ! id "btsave" &>/dev/null; then
  echo "👤 Creating btsave user..."
  useradd -r -s /bin/false btsave
fi

# Sync files
echo "📁 Syncing files..."
rm -rf $APP_DIR
cp -r $SOURCE_DIR $APP_DIR

# Install dependencies
echo "📦 Installing dependencies..."
cd $APP_DIR
npm install --production

# Set permissions
echo "🔒 Setting permissions..."
chown -R btsave:btsave $APP_DIR

# Start service
echo "▶️  Starting service..."
systemctl daemon-reload
systemctl enable btsave
systemctl start btsave

# Check status
echo "✅ Deployment complete!"
systemctl status btsave --no-pager
