#!/usr/bin/env bash
# setup-samantha.sh — Bootstrap a fresh Samantha (Orgo) VM for zero-manual-steps operation.
#
# All secrets are pulled automatically from macOS Keychain:
#   codex.refresh-token  — ChatGPT Pro OAuth refresh token
#   codex.account-id     — ChatGPT account UUID
#   aitoearn.api-key     — AiToEarn API key
#   composio.api-key     — Composio API key
#   (account: gagan@getfoolish.com for all)
#
# Override any secret via environment variable if Keychain is unavailable.
#
# Idempotent: safe to re-run on an existing VM.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INT="$REPO_ROOT/integrations/samantha"
KEYCHAIN_ACCOUNT="gagan@getfoolish.com"

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo "    $*"; }

keychain_get() {
  security find-generic-password -s "$1" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 0. Resolve all secrets (Keychain → env var → fail)
# ---------------------------------------------------------------------------
log "0/8  Resolving secrets"

[[ -z "${CODEX_REFRESH_TOKEN:-}" ]]  && CODEX_REFRESH_TOKEN="$(keychain_get codex.refresh-token)"
[[ -z "${CODEX_ACCOUNT_ID:-}" ]]     && CODEX_ACCOUNT_ID="$(keychain_get codex.account-id)"
[[ -z "${AITOEARN_API_KEY:-}" ]]     && AITOEARN_API_KEY="$(keychain_get aitoearn.api-key)"
[[ -z "${COMPOSIO_API_KEY:-}" ]]     && COMPOSIO_API_KEY="$(keychain_get composio.api-key)"

[[ -n "$CODEX_REFRESH_TOKEN" ]] || die "CODEX_REFRESH_TOKEN not found. Add to Keychain: security add-generic-password -s codex.refresh-token -a $KEYCHAIN_ACCOUNT -w <token>"
[[ -n "$CODEX_ACCOUNT_ID" ]]    || die "CODEX_ACCOUNT_ID not found."
[[ -n "$AITOEARN_API_KEY" ]]    || die "AITOEARN_API_KEY not found."
[[ -n "$COMPOSIO_API_KEY" ]]    || die "COMPOSIO_API_KEY not found."

step "All secrets resolved."

# ---------------------------------------------------------------------------
# 1. Fix DNS (broken resolv.conf symlink on Orgo VMs)
# ---------------------------------------------------------------------------
log "1/8  Fix DNS"
rm -f /etc/resolv.conf
printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf
install -m644 "$INT/fix-dns.conf" /etc/supervisor/conf.d/fix-dns.conf
step "Done."

# ---------------------------------------------------------------------------
# 2. Seed /root/.env with all secrets
# ---------------------------------------------------------------------------
log "2/8  Seed /root/.env"
ENV_FILE="/root/.env"
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"

seed_env() {
  local key="$1" val="$2"
  if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    echo "${key}=${val}" >> "$ENV_FILE"
    step "${key} written"
  else
    step "${key} already present — skipping"
  fi
}

seed_env CODEX_REFRESH_TOKEN "$CODEX_REFRESH_TOKEN"
seed_env CODEX_ACCOUNT_ID    "$CODEX_ACCOUNT_ID"
seed_env AITOEARN_API_KEY    "$AITOEARN_API_KEY"
seed_env COMPOSIO_API_KEY    "$COMPOSIO_API_KEY"

# ---------------------------------------------------------------------------
# 3. Install Hermes config + SOUL
# ---------------------------------------------------------------------------
log "3/8  Install Hermes config + SOUL"
mkdir -p /root/.hermes

# Deploy config.yaml from template (envsubst substitutes ${VAR} placeholders)
export AITOEARN_API_KEY COMPOSIO_API_KEY
envsubst < "$INT/config.yaml.template" > /root/.hermes/config.yaml
step "config.yaml deployed"

install -m644 "$INT/SOUL.md" /root/.hermes/SOUL.md
step "SOUL.md deployed"

# ---------------------------------------------------------------------------
# 4. Install Claude Code MCP config
# ---------------------------------------------------------------------------
log "4/8  Install Claude Code MCP config"
mkdir -p /root/.claude
export AITOEARN_API_KEY
envsubst < "$INT/claude_desktop_config.json.template" > /root/.claude/claude_desktop_config.json
step "claude_desktop_config.json deployed"

# ---------------------------------------------------------------------------
# 5. Install Codex token refresh (auth automation)
# ---------------------------------------------------------------------------
log "5/8  Install Codex token refresh"
install -m755 "$INT/codex-token-refresh.py"  /root/codex-token-refresh.py
install -m755 "$INT/restore-codex-auth.sh"   /root/restore-codex-auth.sh
install -m644 "$INT/restore-codex-auth.conf" /etc/supervisor/conf.d/restore-codex-auth.conf

CRON_JOB="0 * * * * /root/restore-codex-auth.sh >> /tmp/codex-token-refresh-cron.log 2>&1"
( crontab -l 2>/dev/null | grep -qF "restore-codex-auth" ) \
  || { crontab -l 2>/dev/null; echo "$CRON_JOB"; } | crontab -
step "Token refresh installed + hourly cron registered"

# ---------------------------------------------------------------------------
# 6. Install hermes-tools MCP bridge + register in Codex
# ---------------------------------------------------------------------------
log "6/8  Install hermes-tools MCP bridge"
install -m755 "$INT/hermes-tools-mcp.py" /root/hermes-tools-mcp.py

CODEX_CFG="$HOME/.codex/config.toml"
mkdir -p "$(dirname "$CODEX_CFG")" && touch "$CODEX_CFG"

if ! grep -q "\[mcp_servers.hermes-tools\]" "$CODEX_CFG" 2>/dev/null; then
  cat >> "$CODEX_CFG" << TOML

[mcp_servers.hermes-tools]
command = "/root/hermes-tools-mcp.py"
args = []
TOML
  step "hermes-tools MCP added to Codex config"
else
  step "hermes-tools MCP already present"
fi

if ! grep -q "\[mcp_servers.playwright\]" "$CODEX_CFG" 2>/dev/null; then
  cat >> "$CODEX_CFG" << TOML

[mcp_servers.playwright]
command = "npx"
args = ["@playwright/mcp", "--headless"]
TOML
  step "playwright MCP added to Codex config"
else
  step "playwright MCP already present"
fi

# ---------------------------------------------------------------------------
# 7. Install remaining supervisor services
# ---------------------------------------------------------------------------
log "7/8  Install supervisor services"
for conf in claude-bridge crond sshd; do
  install -m644 "$INT/$conf.conf" /etc/supervisor/conf.d/$conf.conf
  step "$conf.conf installed"
done

# ---------------------------------------------------------------------------
# 8. Reload supervisor + initial Codex token refresh
# ---------------------------------------------------------------------------
log "8/8  Reload supervisor + initial Codex token refresh"
supervisorctl reload 2>/dev/null || true
sleep 3
python3 /root/codex-token-refresh.py

echo
echo "================================================================"
echo "Samantha setup complete — zero manual steps."
echo ""
echo "Verify:"
echo "  supervisorctl status"
echo "  tail /tmp/claude-bridge.log"
echo "  tail /tmp/restore-codex-auth.log"
echo "  codex exec --skip-git-repo-check \"say CODEX_OK\""
echo "================================================================"
