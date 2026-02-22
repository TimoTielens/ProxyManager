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

# ── 1.6 Configure SSH + allow root login ─────────────────────────────────────
log "Installing OpenSSH server..."
tdnf install -y openssh-server

log "Allowing root login via SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
elif grep -q "^#PermitRootLogin" "$SSHD_CONFIG"; then
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
else
  echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
fi
ok "PermitRootLogin set to yes."

log "Enabling and starting SSH service..."
systemctl is-enabled sshd >/dev/null 2>&1 || systemctl enable sshd
systemctl is-active  sshd >/dev/null 2>&1 || systemctl start  sshd || systemctl restart sshd
ok "SSH is installed and running."

# ─────────────────────────────────────────────────────────────────────────────
reboot now