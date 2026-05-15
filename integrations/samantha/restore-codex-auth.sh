#!/usr/bin/env bash
# restore-codex-auth.sh — Boot-time Codex token refresh.
# Called by supervisor at priority=2 (after fix-dns ensures DNS is up).
# Also runs hourly via cron to keep tokens fresh before the 1h expiry window.
set -euo pipefail
exec python3 /root/codex-token-refresh.py
