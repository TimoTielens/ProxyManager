#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Bootstrap NPMplus + CrowdSec stack
# =============================================================================
set -euo pipefail

ENV_FILE=".env"
BOUNCER_NAME="npmplus-bouncer"

log()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERR ]\033[0m  $*" >&2; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v docker   >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not installed."

[[ -f "$ENV_FILE" ]] || { warn ".env not found — copying from .env.example"; cp .env.example "$ENV_FILE" 2>/dev/null || die "No .env or .env.example found."; }

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

# ── Step 3: Bring up the full stack ──────────────────────────────────────────
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
