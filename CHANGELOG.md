# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **PM2 process management** - Auto-restart, log management, graceful shutdown (dev dependency)
- **Systemd service** - Starts on boot, runs as dedicated user (`btsave`)
- **Health endpoint** (`GET /health`) - Returns status, uptime, memory info
- **Deployment script** (`deploy.sh`) - One-command deployment to /opt/btsave
- **Nginx reverse proxy** - SSL termination with Let's Encrypt
- **Security headers** - Helmet.js middleware
- **Rate limiting** - Protection against abuse

### Security
- App now runs as non-root user (`btsave`)
- Secrets managed via environment (not committed to git)
- Nginx handles HTTPS/SSL
- Rate limiting enabled

### Infrastructure
- Deployment scripts for easy updates
- Log rotation configured
- Health checks for container orchestration

---

## [1.0.0] - 2026-02-14

### Added
- Initial release
- Core functionality: server, notifier, dashboard
