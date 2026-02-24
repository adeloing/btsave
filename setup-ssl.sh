#!/bin/bash
# SSL Setup Script
# Run this once your domain points to this server

DOMAIN="ratpoison2.duckdns.org"
EMAIL="picoclaw@openclaw.ai"

echo "Setting up SSL for $DOMAIN..."

# Stop nginx temporarily
systemctl stop nginx

# Get SSL certificate
certbot certonly --standalone -d $DOMAIN --agree-tos --email $EMAIL --non-interactive

# Update nginx config with SSL
cat > /etc/nginx/sites-available/btsave << 'EOF'
# HTTP (redirects to HTTPS)
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS
server {
    listen 443 ssl;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location /hedge {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    location /health {
        proxy_pass http://localhost:3001/health;
        proxy_set_header Host $host;
    }
}
EOF

sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/btsave

# Restart nginx
systemctl restart nginx

# Setup auto-renewal
certbot renew --dry-run

echo "✅ SSL setup complete!"
