#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  n8n-agent-control.sh --prompt "task for Samantha"
  echo "task for Samantha" | n8n-agent-control.sh

Environment:
  SAMANTHA_AGENT_CONTROL_MODE=full|dry-run   Default: full
  SAMANTHA_AGENT_RUNTIME=codex|auto|hermes   Default: codex
  SAMANTHA_AGENT_WORKDIR=/root               Default: /root
  SAMANTHA_AGENT_LOG_DIR=/root/.hermes/logs/n8n-agent-control
  SAMANTHA_AGENT_TIMEOUT_SECONDS=900
  SAMANTHA_AGENT_COMMAND="custom command"    Optional override
USAGE
}

CONTROL_MODE="${SAMANTHA_AGENT_CONTROL_MODE:-full}"
RUNTIME="${SAMANTHA_AGENT_RUNTIME:-codex}"
WORKDIR="${SAMANTHA_AGENT_WORKDIR:-/root}"
LOG_DIR="${SAMANTHA_AGENT_LOG_DIR:-/root/.hermes/logs/n8n-agent-control}"
MAX_SECONDS="${SAMANTHA_AGENT_TIMEOUT_SECONDS:-900}"
CUSTOM_COMMAND="${SAMANTHA_AGENT_COMMAND:-}"

PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      if [[ $# -lt 2 ]]; then
        echo "--prompt requires a value" >&2
        exit 64
      fi
      PROMPT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$PROMPT" ]] && ! [[ -t 0 ]]; then
  PROMPT="$(cat)"
fi

if [[ -z "${PROMPT//[[:space:]]/}" ]]; then
  echo "Samantha agent control requires a non-empty prompt." >&2
  exit 64
fi

case "$CONTROL_MODE" in
  full|dry-run) ;;
  *)
    echo "SAMANTHA_AGENT_CONTROL_MODE must be full or dry-run." >&2
    exit 64
    ;;
esac

case "$RUNTIME" in
  auto|hermes|codex) ;;
  *)
    echo "SAMANTHA_AGENT_RUNTIME must be auto, hermes, or codex." >&2
    exit 64
    ;;
esac

if [[ ! -d "$WORKDIR" ]]; then
  echo "SAMANTHA_AGENT_WORKDIR does not exist: $WORKDIR" >&2
  exit 66
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="$LOG_DIR/$RUN_ID"
PROMPT_FILE="$RUN_DIR/prompt.txt"
STDOUT_FILE="$RUN_DIR/stdout.log"
STDERR_FILE="$RUN_DIR/stderr.log"
META_FILE="$RUN_DIR/meta.json"

mkdir -p "$RUN_DIR"
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"
: > "$STDOUT_FILE"
: > "$STDERR_FILE"

write_meta() {
  local ok="$1"
  local exit_code="$2"
  local runtime="$3"
  local started_at="$4"
  local finished_at="$5"
  python3 - "$META_FILE" <<'PY' "$ok" "$exit_code" "$runtime" "$CONTROL_MODE" "$started_at" "$finished_at" "$RUN_ID" "$PROMPT_FILE" "$STDOUT_FILE" "$STDERR_FILE"
import json
import sys

path = sys.argv[1]
payload = {
    "ok": sys.argv[2] == "true",
    "exit_code": int(sys.argv[3]),
    "runtime": sys.argv[4],
    "mode": sys.argv[5],
    "started_at": sys.argv[6],
    "finished_at": sys.argv[7],
    "run_id": sys.argv[8],
    "prompt_file": sys.argv[9],
    "stdout_file": sys.argv[10],
    "stderr_file": sys.argv[11],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(payload, sort_keys=True))
PY
}

agent_prompt() {
  cat <<PROMPT
You are Samantha running from an n8n workflow on this computer.

Control mode: $CONTROL_MODE.
Use the configured local Hermes/Codex runtime, plugins, MCP servers, browser tools,
and connected accounts to complete the requested task. Prefer auditable actions,
leave useful logs, and report what changed. For destructive or financially
irreversible actions, make the action explicit before performing it unless the
workflow task unambiguously requested that exact action.

Task:
$PROMPT
PROMPT
}

select_runtime() {
  if [[ -n "$CUSTOM_COMMAND" ]]; then
    echo "custom"
  elif [[ "$RUNTIME" == "hermes" ]]; then
    echo "hermes"
  elif [[ "$RUNTIME" == "codex" ]]; then
    echo "codex"
  elif command -v hermes >/dev/null 2>&1; then
    echo "hermes"
  elif command -v codex >/dev/null 2>&1; then
    echo "codex"
  else
    echo "none"
  fi
}

run_custom() {
  cd "$WORKDIR"
  SAMANTHA_AGENT_PROMPT_FILE="$PROMPT_FILE" timeout "$MAX_SECONDS" bash -lc "$CUSTOM_COMMAND" > "$STDOUT_FILE" 2> "$STDERR_FILE"
}

run_hermes() {
  local prompt_text
  prompt_text="$(agent_prompt)"
  cd "$WORKDIR"
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-bridge-passthrough}" timeout "$MAX_SECONDS" hermes -z "$prompt_text" > "$STDOUT_FILE" 2> "$STDERR_FILE"
}

run_codex() {
  cd "$WORKDIR"
  timeout "$MAX_SECONDS" codex exec --skip-git-repo-check "$(agent_prompt)" > "$STDOUT_FILE" 2> "$STDERR_FILE" < /dev/null
}

agent_output_failed() {
  local failure_pattern
  failure_pattern='API call failed|Connection error|authentication failed|unauthorized|missing api key'
  grep -Eiq -- "$failure_pattern" "$STDOUT_FILE" "$STDERR_FILE"
}

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SELECTED_RUNTIME="$(select_runtime)"

if [[ "$CONTROL_MODE" == "dry-run" ]]; then
  FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_meta true 0 "$SELECTED_RUNTIME" "$STARTED_AT" "$FINISHED_AT"
  exit 0
fi

set +e
case "$SELECTED_RUNTIME" in
  custom)
    run_custom
    EXIT_CODE=$?
    ;;
  hermes)
    run_hermes
    EXIT_CODE=$?
    if [[ "$RUNTIME" == "auto" ]] && agent_output_failed && command -v codex >/dev/null 2>&1; then
      SELECTED_RUNTIME="codex"
      {
        echo "Hermes returned an agent/API failure in auto mode; falling back to Codex."
        echo "--- hermes stdout ---"
        cat "$STDOUT_FILE"
        echo "--- hermes stderr ---"
        cat "$STDERR_FILE"
      } > "$RUN_DIR/hermes-fallback.log"
      run_codex
      EXIT_CODE=$?
    fi
    ;;
  codex)
    run_codex
    EXIT_CODE=$?
    ;;
  none)
    echo "Neither hermes nor codex was found on PATH. Install one or set SAMANTHA_AGENT_COMMAND." > "$STDERR_FILE"
    EXIT_CODE=127
    ;;
esac
set -e

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$EXIT_CODE" -eq 0 ]]; then
  write_meta true "$EXIT_CODE" "$SELECTED_RUNTIME" "$STARTED_AT" "$FINISHED_AT"
else
  write_meta false "$EXIT_CODE" "$SELECTED_RUNTIME" "$STARTED_AT" "$FINISHED_AT"
fi
exit "$EXIT_CODE"
