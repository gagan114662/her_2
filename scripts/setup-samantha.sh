#!/usr/bin/env bash
# setup-samantha.sh — Bootstrap a fresh Samantha (Orgo) VM for zero-manual-steps operation.
#
# Codex credentials are pulled automatically from macOS Keychain (service names:
#   codex.refresh-token / codex.account-id, account: gagan@getfoolish.com).
#
# Override at the command line if needed:
#   CODEX_REFRESH_TOKEN=rt_... CODEX_ACCOUNT_ID=... bash scripts/setup-samantha.sh
#
# Idempotent: safe to re-run; existing config is not overwritten unless content differs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATIONS="$REPO_ROOT/integrations/samantha"
KEYCHAIN_ACCOUNT="gagan@getfoolish.com"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

keychain_get() {
  local service="$1"
  security find-generic-password -s "$service" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Resolve Codex credentials (Keychain → env var → fail)
# ---------------------------------------------------------------------------
log "0/6  Resolving Codex credentials"

if [[ -z "${CODEX_REFRESH_TOKEN:-}" ]]; then
  CODEX_REFRESH_TOKEN="$(keychain_get codex.refresh-token)"
fi
if [[ -z "${CODEX_ACCOUNT_ID:-}" ]]; then
  CODEX_ACCOUNT_ID="$(keychain_get codex.account-id)"
fi

[[ -n "$CODEX_REFRESH_TOKEN" ]] || die "CODEX_REFRESH_TOKEN not found in Keychain or environment. Run: security add-generic-password -s codex.refresh-token -a $KEYCHAIN_ACCOUNT -w <token>"
[[ -n "$CODEX_ACCOUNT_ID"    ]] || die "CODEX_ACCOUNT_ID not found in Keychain or environment."

echo "   Credentials resolved."

# ---------------------------------------------------------------------------
# 1. Fix DNS (broken resolv.conf symlink on Orgo VMs)
# ---------------------------------------------------------------------------
log "1/6  Fix DNS"
rm -f /etc/resolv.conf
printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf
install -m644 "$INTEGRATIONS/fix-dns.conf" /etc/supervisor/conf.d/fix-dns.conf
echo "   /etc/resolv.conf fixed; supervisor fix-dns.conf installed"

# ---------------------------------------------------------------------------
# 2. Seed /root/.env with Codex credentials
# ---------------------------------------------------------------------------
log "2/6  Seed Codex credentials"
ENV_FILE="/root/.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

if ! grep -q "^CODEX_REFRESH_TOKEN=" "$ENV_FILE" 2>/dev/null; then
  echo "CODEX_REFRESH_TOKEN=$CODEX_REFRESH_TOKEN" >> "$ENV_FILE"
  echo "   CODEX_REFRESH_TOKEN written"
else
  echo "   CODEX_REFRESH_TOKEN already present — skipping (existing rotated value preserved)"
fi
if ! grep -q "^CODEX_ACCOUNT_ID=" "$ENV_FILE" 2>/dev/null; then
  echo "CODEX_ACCOUNT_ID=$CODEX_ACCOUNT_ID" >> "$ENV_FILE"
  echo "   CODEX_ACCOUNT_ID written"
else
  echo "   CODEX_ACCOUNT_ID already present — skipping"
fi

# ---------------------------------------------------------------------------
# 3. Install Codex token refresh scripts
# ---------------------------------------------------------------------------
log "3/6  Install Codex token refresh"
install -m755 "$INTEGRATIONS/codex-token-refresh.py" /root/codex-token-refresh.py
install -m755 "$INTEGRATIONS/restore-codex-auth.sh"  /root/restore-codex-auth.sh
install -m644 "$INTEGRATIONS/restore-codex-auth.conf" /etc/supervisor/conf.d/restore-codex-auth.conf
echo "   codex-token-refresh.py, restore-codex-auth.sh, supervisor conf installed"

CRON_JOB="0 * * * * /root/restore-codex-auth.sh >> /tmp/codex-token-refresh-cron.log 2>&1"
( crontab -l 2>/dev/null | grep -qF "/root/restore-codex-auth.sh" ) \
  || ( crontab -l 2>/dev/null; echo "$CRON_JOB" ) | crontab -
echo "   Hourly cron job registered"

# ---------------------------------------------------------------------------
# 4. Install Hermes Tools MCP bridge
# ---------------------------------------------------------------------------
log "4/6  Install hermes-tools MCP bridge"
install -m755 "$INTEGRATIONS/hermes-tools-mcp.py" /root/hermes-tools-mcp.py

CODEX_CFG="$HOME/.codex/config.toml"
mkdir -p "$(dirname "$CODEX_CFG")"
touch "$CODEX_CFG"

if ! grep -q "\[mcp_servers.hermes-tools\]" "$CODEX_CFG" 2>/dev/null; then
  cat >> "$CODEX_CFG" << TOML

[mcp_servers.hermes-tools]
command = "/root/hermes-tools-mcp.py"
args = []
TOML
  echo "   hermes-tools MCP added to $CODEX_CFG"
else
  echo "   hermes-tools MCP already present — skipping"
fi

if ! grep -q "\[mcp_servers.playwright\]" "$CODEX_CFG" 2>/dev/null; then
  cat >> "$CODEX_CFG" << TOML

[mcp_servers.playwright]
command = "npx"
args = ["@playwright/mcp", "--headless"]
TOML
  echo "   playwright MCP added to $CODEX_CFG"
else
  echo "   playwright MCP already present — skipping"
fi

# ---------------------------------------------------------------------------
# 5. Set Hermes runtime to codex_app_server + yolo mode
# ---------------------------------------------------------------------------
log "5/6  Configure Hermes runtime"
hermes config set agent.runtime codex_app_server 2>/dev/null || true
hermes config set agent.yolo true                2>/dev/null || true
hermes config set hooks_auto_accept true         2>/dev/null || true
echo "   Hermes: runtime=codex_app_server, yolo=true, hooks_auto_accept=true"

# ---------------------------------------------------------------------------
# 6. Reload supervisor + perform initial token refresh
# ---------------------------------------------------------------------------
log "6/6  Reload supervisor and perform initial Codex token refresh"
supervisorctl reload 2>/dev/null || true
sleep 3

python3 /root/codex-token-refresh.py

echo
echo "================================================================"
echo "Samantha setup complete — zero manual steps required."
echo ""
echo "Verify:"
echo "  tail /tmp/restore-codex-auth.log"
echo "  cat /root/.codex/auth.json | python3 -c \"import sys,json; d=json.load(sys.stdin); print('OK:', d['tokens']['account_id'])\""
echo "  codex exec --skip-git-repo-check \"say CODEX_OK\""
echo "================================================================"
