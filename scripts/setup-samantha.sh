#!/usr/bin/env bash
# setup-samantha.sh — configure a fresh Samantha VM with the Codex app-server runtime.
# Run as root on the Orgo VM.
set -euo pipefail

echo "==> 1/5  Fix DNS (broken resolv.conf symlink)"
rm -f /etc/resolv.conf
printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf
cp "$(dirname "$0")/../integrations/samantha/fix-dns.conf" /etc/supervisor/conf.d/fix-dns.conf

echo "==> 2/5  Install Hermes Tools MCP bridge"
cp "$(dirname "$0")/../integrations/samantha/hermes-tools-mcp.py" /root/hermes-tools-mcp.py
chmod +x /root/hermes-tools-mcp.py

echo "==> 3/5  Register hermes-tools + playwright in Codex config"
CODEX_CFG="$HOME/.codex/config.toml"
if ! grep -q "\[mcp_servers.hermes-tools\]" "$CODEX_CFG" 2>/dev/null; then
  cat >> "$CODEX_CFG" << TOML

[mcp_servers.hermes-tools]
command = "/root/hermes-tools-mcp.py"
args = []

[mcp_servers.playwright]
command = "npx"
args = ["@playwright/mcp", "--headless"]
TOML
  echo "   Added hermes-tools + playwright to $CODEX_CFG"
else
  echo "   Already present — skipping"
fi

echo "==> 4/5  Set Hermes runtime to codex_app_server + yolo mode"
hermes config set agent.runtime codex_app_server    2>/dev/null || true
hermes config set agent.yolo true                   2>/dev/null || true
hermes config set hooks_auto_accept true            2>/dev/null || true

echo "==> 5/5  Reload supervisor"
supervisorctl reload 2>/dev/null || true

echo
echo "Done. Verify with:"
echo "  cd /root && codex exec --skip-git-repo-check \"say CODEX_OK\""
