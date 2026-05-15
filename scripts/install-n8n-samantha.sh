#!/usr/bin/env bash
set -euo pipefail

# Reproducible n8n install for Samantha-style Ubuntu VMs.
# This preserves the live fix for issue #29: npm global installs can hang or
# leave corrupt partial installs, while pnpm plus an explicit sqlite3 rebuild
# produced a healthy n8n service on port 5678.

N8N_VERSION="${N8N_VERSION:-1.63.4}"
PNPM_VERSION="${PNPM_VERSION:-9.15.9}"
N8N_PORT="${N8N_PORT:-5678}"
N8N_HOST="${N8N_HOST:-0.0.0.0}"
N8N_USER_FOLDER="${N8N_USER_FOLDER:-/root/.n8n}"
HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
PNPM_STORE_DIR="${PNPM_STORE_DIR:-/root/.pnpm-store}"
LOG_FILE="${LOG_FILE:-/root/n8n-install-issue29.log}"
START_SCRIPT="${START_SCRIPT:-${HERMES_HOME}/bin/start-n8n.sh}"
AGENT_CONTROL_SCRIPT="${AGENT_CONTROL_SCRIPT:-${HERMES_HOME}/bin/n8n-agent-control.sh}"
WORKFLOW_AUTHOR_SCRIPT="${WORKFLOW_AUTHOR_SCRIPT:-${HERMES_HOME}/bin/n8n-workflow-author.sh}"
PID_FILE="${PID_FILE:-${HERMES_HOME}/n8n.pid}"
RUN_LOG="${RUN_LOG:-${HERMES_HOME}/logs/n8n.log}"

export PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

bounded() {
  local seconds="$1"
  shift
  timeout "$seconds" "$@"
}

clean_rebuildable_caches() {
  npm cache clean --force >/dev/null 2>&1 || true
  rm -rf /root/.npm/_cacache /root/.npm/_logs /root/.npm/_npx
  rm -rf /root/.cache/uv/archive-v0 /root/.cache/uv/sdists-v9 /root/.cache/uv/wheels-v6
  rm -rf /root/.cache/pip/http-v2 /root/.cache/pip/wheels
}

install_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then
    log "pnpm already installed: $(pnpm --version)"
    return
  fi
  log "installing pnpm $PNPM_VERSION"
  bounded 60 npm install -g "pnpm@$PNPM_VERSION" --no-audit --no-fund --loglevel=error
}

install_n8n() {
  log "removing incomplete n8n installs"
  rm -rf /usr/local/lib/node_modules/n8n /usr/local/bin/n8n /usr/bin/n8n

  export PNPM_HOME="/usr/local/bin"
  export PNPM_STORE_DIR

  log "installing n8n $N8N_VERSION with pnpm"
  bounded 240 pnpm add -g "n8n@${N8N_VERSION}" \
    --ignore-scripts \
    --config.confirmModulesPurge=false \
    --config.store-dir="$PNPM_STORE_DIR" \
    --global-bin-dir=/usr/local/bin

  command -v n8n
  n8n --version
}

real_n8n_dir() {
  node <<'NODE'
const fs = require('fs');
const shim = fs.readFileSync('/usr/local/bin/n8n', 'utf8');
const match = shim.match(/(\/usr\/local\/bin\/global\/5\/\.pnpm\/[^:"]+\/node_modules\/n8n)\/node_modules/);
if (!match) process.exit(1);
console.log(match[1]);
NODE
}

repair_sqlite() {
  export PNPM_HOME="/usr/local/bin"
  export PNPM_STORE_DIR

  log "installing sqlite3 dependency"
  bounded 90 pnpm add -g sqlite3@5.1.7 \
    --config.store-dir="$PNPM_STORE_DIR" \
    --global-bin-dir=/usr/local/bin

  local sqlite_dir
  sqlite_dir="$(readlink -f /usr/local/bin/global/5/node_modules/sqlite3)"
  test -d "$sqlite_dir"

  local n8n_dir
  n8n_dir="$(real_n8n_dir)"
  mkdir -p "$n8n_dir/node_modules" /usr/local/bin/global/5/.pnpm/node_modules
  ln -sfn "$sqlite_dir" "$n8n_dir/node_modules/sqlite3"
  ln -sfn "$sqlite_dir" /usr/local/bin/global/5/.pnpm/node_modules/sqlite3

  # pnpm installs n8n with lifecycle scripts disabled to avoid the hang. The
  # sqlite3 native binding still has to be built/downloaded before n8n starts.
  log "rebuilding sqlite3 native binding"
  (
    cd "$sqlite_dir"
    bounded 150 npm rebuild sqlite3 --build-from-source=false --loglevel=notice
  )

  NODE_PATH="/usr/local/bin/global/5/node_modules:/usr/local/bin/global/5/.pnpm/node_modules" \
    node -e "require('module').Module._initPaths(); const s = require('sqlite3'); console.log('sqlite ok', s.VERSION || 'loaded')"
}

write_start_script() {
  mkdir -p "$(dirname "$START_SCRIPT")" "$(dirname "$RUN_LOG")" "$N8N_USER_FOLDER"
  cat >"$START_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export NODE_PATH="/usr/local/bin/global/5/node_modules:/usr/local/bin/global/5/.pnpm/node_modules:${NODE_PATH:-}"
export N8N_HOST="${N8N_HOST:-0.0.0.0}"
export N8N_PORT="${N8N_PORT:-5678}"
export N8N_PROTOCOL="${N8N_PROTOCOL:-http}"
export N8N_USER_FOLDER="${N8N_USER_FOLDER:-/root/.n8n}"
export N8N_SECURE_COOKIE="${N8N_SECURE_COOKIE:-false}"
export N8N_DIAGNOSTICS_ENABLED="${N8N_DIAGNOSTICS_ENABLED:-false}"
export N8N_VERSION_NOTIFICATIONS_ENABLED="${N8N_VERSION_NOTIFICATIONS_ENABLED:-false}"
exec n8n start
SH
  chmod +x "$START_SCRIPT"
}

install_helper_scripts() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "${HERMES_HOME}/bin"

  if [[ -f "${script_dir}/n8n-agent-control.sh" ]]; then
    install -m 0755 "${script_dir}/n8n-agent-control.sh" "$AGENT_CONTROL_SCRIPT"
    log "installed n8n agent bridge at $AGENT_CONTROL_SCRIPT"
  else
    log "n8n agent bridge not found beside installer; skipping helper install"
  fi

  if [[ -f "${script_dir}/n8n-workflow-author.sh" ]]; then
    install -m 0755 "${script_dir}/n8n-workflow-author.sh" "$WORKFLOW_AUTHOR_SCRIPT"
    log "installed n8n workflow author at $WORKFLOW_AUTHOR_SCRIPT"
  else
    log "n8n workflow author not found beside installer; skipping helper install"
  fi
}

start_n8n() {
  local pids
  pids="$(ps -eo pid=,cmd= | awk '/n8n start|start-n8n/ && !/awk/ {print $1}')"
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    sleep 2
  fi

  nohup "$START_SCRIPT" >"$RUN_LOG" 2>&1 &
  echo "$!" >"$PID_FILE"
  log "started n8n pid $(cat "$PID_FILE")"
}

wait_for_healthz() {
  local url="http://127.0.0.1:${N8N_PORT}/healthz"
  local code
  for _ in $(seq 1 60); do
    code="$(curl -sS -o /tmp/n8n-health.out -w '%{http_code}' "$url" 2>/tmp/n8n-health.err || true)"
    if [ "$code" = "200" ]; then
      log "healthz=200 $(cat /tmp/n8n-health.out)"
      return 0
    fi
    sleep 2
  done

  log "n8n did not become healthy"
  tail -120 "$RUN_LOG" 2>/dev/null || true
  return 1
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1

  log "starting n8n install"
  df -h /
  clean_rebuildable_caches
  install_pnpm
  install_n8n
  repair_sqlite
  write_start_script
  install_helper_scripts
  start_n8n
  wait_for_healthz
  df -h /
  log "n8n install complete"
}

main "$@"
