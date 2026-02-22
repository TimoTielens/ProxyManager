#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Bootstrap NPMplus + CrowdSec stack on VMware Photon OS
# =============================================================================
set -euo pipefail

ENV_FILE=".env"
BOUNCER_NAME="npmplus-bouncer"

log()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERR ]\033[0m  $*" >&2; exit 1; }

# =============================================================================
# SECTION 1 — Photon OS System Preparation
# =============================================================================

# ── 1.1 Photon OS version ─────────────────────────────────────────────────────
log "Checking Photon OS version..."
if [[ -f /etc/photon-release ]]; then
  PHOTON_VERSION=$(cat /etc/photon-release)
  ok "Running on: ${PHOTON_VERSION}"
elif [[ -f /etc/os-release ]]; then
  source /etc/os-release
  ok "Running on: ${PRETTY_NAME:-Unknown OS}"
  [[ "${ID:-}" == "photon" ]] || warn "This script is optimised for VMware Photon OS."
else
  die "Cannot determine OS version. Is this Photon OS?"
fi

# ── 1.2 Remove password expiration policy ────────────────────────────────────
log "Removing password expiration policy..."
# Set maximum password age to 'never' (99999 days) for all non-system users
chage --maxdays 99999 root 2>/dev/null || true
# Also disable expiry in the global login.defs
if [[ -f /etc/login.defs ]]; then
  sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   99999/' /etc/login.defs
  sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   0/'     /etc/login.defs
  sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   0/'     /etc/login.defs
fi
ok "Password expiration policy disabled."

# ── 1.3 Update and upgrade Photon OS ─────────────────────────────────────────
log "Updating package list and upgrading system (this may take a while)..."
tdnf check-update -y || true   # non-zero exit is normal when updates exist
tdnf upgrade -y
ok "System is up to date."

# ── 1.4 Install Docker + Docker Compose ──────────────────────────────────────
log "Installing Docker..."
tdnf install -y docker

log "Enabling and starting Docker service..."
systemctl is-enabled docker >/dev/null 2>&1 || systemctl enable docker
systemctl is-active  docker >/dev/null 2>&1 || systemctl start  docker
ok "Docker is installed and running."

# Verify compose plugin
if ! docker compose version >/dev/null 2>&1; then
  log "Installing Docker Compose plugin..."
  tdnf install -y docker-compose
fi
ok "Docker Compose: $(docker compose version --short)"

# ── 1.5 Install ping (iputils) ───────────────────────────────────────────────
log "Installing ping (iputils)..."
tdnf install -y iputils
ok "ping installed: $(ping -V 2>&1 | head -1)"

# ── 1.6 Install QEMU Guest Agent ─────────────────────────────────────────────
log "Installing QEMU Guest Agent..."
tdnf install -y qemu-guest-agent
systemctl is-enabled qemu-guest-agent >/dev/null 2>&1 || systemctl enable qemu-guest-agent
systemctl is-active  qemu-guest-agent >/dev/null 2>&1 || systemctl start  qemu-guest-agent
ok "QEMU Guest Agent installed and running."

# =============================================================================
# SECTION 2 — NPMplus + CrowdSec Stack Deployment
# =============================================================================

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "Docker is not available after installation — check errors above."
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available — check errors above."

[[ -f "$ENV_FILE" ]] || {
  warn ".env not found — copying from .env.example"
  cp .env.example "$ENV_FILE" 2>/dev/null || die "No .env or .env.example found."
}

# ── Step 1: Start CrowdSec first so we can register a bouncer ─────────────────
log "Starting CrowdSec..."
docker compose up -d crowdsec

log "Waiting for CrowdSec to become ready (up to 30s)..."
for i in $(seq 1 30); do
  if docker exec crowdsec cscli version >/dev/null 2>&1; then
    ok "CrowdSec is ready."
    break
  fi
  [[ $i -eq 30 ]] && die "CrowdSec did not become ready in time."
  sleep 1
done

# ── Step 2: Register / retrieve bouncer key ───────────────────────────────────
EXISTING_KEY=$(grep "^CROWDSEC_BOUNCER_KEY=" "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]')

if [[ -z "$EXISTING_KEY" ]]; then
  log "Registering CrowdSec bouncer '${BOUNCER_NAME}'..."

  # Remove stale bouncer if re-running the script
  docker exec crowdsec cscli bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true

  BOUNCER_KEY=$(docker exec crowdsec cscli bouncers add "$BOUNCER_NAME" -o raw)
  [[ -z "$BOUNCER_KEY" ]] && die "Failed to generate bouncer key."

  # Write key into .env
  if grep -q "^CROWDSEC_BOUNCER_KEY=" "$ENV_FILE"; then
    sed -i "s|^CROWDSEC_BOUNCER_KEY=.*|CROWDSEC_BOUNCER_KEY=${BOUNCER_KEY}|" "$ENV_FILE"
  else
    echo "CROWDSEC_BOUNCER_KEY=${BOUNCER_KEY}" >> "$ENV_FILE"
  fi

  ok "Bouncer key saved to ${ENV_FILE}."
else
  ok "Bouncer key already present in ${ENV_FILE}, skipping registration."
  BOUNCER_KEY="$EXISTING_KEY"
fi

# ── Step 3: Bring up the full stack ───────────────────────────────────────────
log "Starting full stack..."
docker compose up -d

ok "All services are up."
echo
log "Service status:"
docker compose ps
echo
log "─────────────────────────────────────────────────────"
log "  NPMplus Admin UI  →  http://$(hostname -I | awk '{print $1}'):81"
log "  Default login     →  admin@example.com / changeme"
log "─────────────────────────────────────────────────────"
warn "Change the default admin password immediately after first login!"
