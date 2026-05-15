#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sync-codex-to-samantha.sh

Environment:
  SAMANTHA_ORGO_COMPUTER_ID       Default: a7cf78dd-66a0-43d8-8f14-ba00c307acf2
  SAMANTHA_CODEX_HOME             Default: $HOME/.codex
  ORGO_API_KEY                    Optional; otherwise read from macOS Keychain
  SAMANTHA_CODEX_SYNC_SMOKE=1     Run a remote codex exec smoke test after sync

This syncs the local Codex auth/config/plugin cache to Samantha's VM, then makes
the remote config Linux-safe by removing Mac-only project paths and local source
paths. It does not print tokens, config contents, or archive bytes.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CODEX_HOME="${SAMANTHA_CODEX_HOME:-$HOME/.codex}"
COMPUTER_ID="${SAMANTHA_ORGO_COMPUTER_ID:-a7cf78dd-66a0-43d8-8f14-ba00c307acf2}"
SMOKE="${SAMANTHA_CODEX_SYNC_SMOKE:-0}"

if [[ ! -d "$CODEX_HOME" ]]; then
  echo "Codex home does not exist: $CODEX_HOME" >&2
  exit 66
fi

if [[ ! -f "$CODEX_HOME/auth.json" ]]; then
  echo "Codex auth.json does not exist: $CODEX_HOME/auth.json" >&2
  exit 66
fi

if [[ -z "${ORGO_API_KEY:-}" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "ORGO_API_KEY is not set and macOS security CLI is unavailable." >&2
    exit 65
  fi
  ORGO_API_KEY="$(security find-generic-password -s ai.orgo.mac.api-key -a default -w)"
  export ORGO_API_KEY
fi

ARCHIVE="$(mktemp -t samantha-codex-sync.XXXXXX.tgz)"
cleanup() {
  rm -f "$ARCHIVE"
}
trap cleanup EXIT

items=()
for item in auth.json config.toml version.json plugins skills; do
  if [[ -e "$CODEX_HOME/$item" ]]; then
    items+=("$item")
  fi
done

COPYFILE_DISABLE=1 tar -C "$CODEX_HOME" -czf "$ARCHIVE" "${items[@]}"

python3 - "$ARCHIVE" "$COMPUTER_ID" "$SMOKE" <<'PY'
import base64
import json
import os
from pathlib import Path
import shlex
import sys
import time
import urllib.error
import urllib.request

archive_path = Path(sys.argv[1])
computer_id = sys.argv[2]
smoke = sys.argv[3] == "1"
api_key = os.environ["ORGO_API_KEY"]

def request(url, method="GET", data=None, headers=None, timeout=120):
    merged = {"Authorization": f"Bearer {api_key}"}
    if headers:
        merged.update(headers)
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        merged["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=merged, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", "replace")
            try:
                return response.status, json.loads(raw)
            except Exception:
                return response.status, raw
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        return error.code, raw

def bash(command, timeout=120):
    status, payload = request(
        f"https://{instance}.orgo.dev/bash",
        method="POST",
        headers={"Authorization": f"Bearer {vnc_token}"},
        data={"command": command},
        timeout=timeout,
    )
    if status >= 300:
        raise SystemExit(f"remote bash HTTP {status}")
    if isinstance(payload, dict):
        if payload.get("exit_code", 0) != 0:
            output = payload.get("output") or ""
            error = payload.get("error") or ""
            raise SystemExit(f"remote command failed: {output[-800:]} {error[-800:]}")
        return payload.get("output") or ""
    return str(payload)

status, info = request(f"https://www.orgo.ai/api/computers/{computer_id}", timeout=30)
if status >= 300:
    raise SystemExit(f"computer lookup failed: HTTP {status}")
computer = info.get("computer") if isinstance(info, dict) else {}
if not isinstance(computer, dict):
    computer = info if isinstance(info, dict) else {}
instance = computer.get("instance_name") or computer.get("fly_instance_id")
if not instance:
    raise SystemExit("could not resolve Samantha Orgo instance")

status, vnc = request(f"https://www.orgo.ai/api/computers/{computer_id}/vnc-password", timeout=30)
if status >= 300:
    raise SystemExit(f"vnc token lookup failed: HTTP {status}")
vnc_token = vnc.get("vnc_password") or vnc.get("password") or vnc.get("token")
if not vnc_token:
    raise SystemExit("could not resolve Samantha VNC token")

stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
remote_archive = f"/tmp/samantha-codex-sync-{stamp}.tgz"
remote_b64 = f"{remote_archive}.b64"

bash(f"rm -f {shlex.quote(remote_archive)} {shlex.quote(remote_b64)} && : > {shlex.quote(remote_b64)}")

encoded = base64.b64encode(archive_path.read_bytes()).decode("ascii")
chunk_size = 96_000
for offset in range(0, len(encoded), chunk_size):
    chunk = encoded[offset : offset + chunk_size]
    command = (
        "python3 - <<'PY2'\n"
        "from pathlib import Path\n"
        f"Path({remote_b64!r}).open('ab').write({chunk!r}.encode('ascii'))\n"
        "PY2\n"
    )
    bash(command, timeout=60)

install = f"""set -euo pipefail
mkdir -p /root/.codex/backups
backup="/root/.codex/backups/cron-sync-{stamp}"
mkdir -p "$backup"
if [[ -d /root/.codex ]]; then
  tar -C /root/.codex -czf "$backup/before-sync.tgz" auth.json config.toml version.json plugins skills 2>/dev/null || true
fi
python3 - <<'PY2'
import base64
from pathlib import Path
Path({remote_archive!r}).write_bytes(base64.b64decode(Path({remote_b64!r}).read_text()))
PY2
mkdir -p /root/.codex
tar --warning=no-unknown-keyword --warning=no-timestamp -xzf {shlex.quote(remote_archive)} -C /root/.codex
chmod 700 /root/.codex
chmod 600 /root/.codex/auth.json /root/.codex/config.toml 2>/dev/null || true
python3 - <<'PY3'
from pathlib import Path
cfg_path = Path('/root/.codex/config.toml')
if cfg_path.exists():
    lines = cfg_path.read_text(errors='replace').splitlines()
    out = []
    section = ''
    skipping_project = False
    removed_projects = 0
    removed_mac_lines = 0
    rewritten_claude = False
    rewrote_zsh_path = False
    shell_zsh_fork_usable = Path('/bin/zsh').exists() or Path('/usr/bin/zsh').exists()
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            section = stripped
            skipping_project = stripped.startswith('[projects."/Users/')
            if skipping_project:
                removed_projects += 1
                continue
        if skipping_project:
            continue
        if '/Users/' in line and (stripped.startswith('notify =') or stripped.startswith('source =')):
            removed_mac_lines += 1
            continue
        if stripped.startswith('zsh_path =') and '/bin/zsh' in line and not Path('/bin/zsh').exists():
            if Path('/usr/bin/zsh').exists():
                out.append('zsh_path = "/usr/bin/zsh"')
            else:
                out.append('zsh_path = "/bin/bash"')
            rewrote_zsh_path = True
            continue
        if stripped.startswith('shell_zsh_fork =') and not shell_zsh_fork_usable:
            out.append('shell_zsh_fork = false')
            continue
        if section == '[mcp_servers.claude]' and stripped.startswith('command =') and '/Users/' in line:
            if Path('/usr/local/bin/claude').exists():
                out.append('command = "/usr/local/bin/claude"')
            else:
                out.append('command = "claude"')
            rewritten_claude = True
            continue
        out.append(line)
    cfg_path.write_text('\\n'.join(out).rstrip() + '\\n')
    final = cfg_path.read_text(errors='replace')
    print('removed_mac_project_sections=' + str(removed_projects))
    print('removed_mac_source_or_notify_lines=' + str(removed_mac_lines))
    print('rewrote_claude_command=' + str(rewritten_claude))
    print('rewrote_zsh_path=' + str(rewrote_zsh_path))
    print('config_has_mac_paths=' + str('/Users/' in final))
PY3
python3 - <<'PY4'
from pathlib import Path
import json
auth = json.loads(Path('/root/.codex/auth.json').read_text())
tokens = auth.get('tokens') or {{}}
cfg = Path('/root/.codex/config.toml').read_text(errors='replace') if Path('/root/.codex/config.toml').exists() else ''
print('auth_has_id_token=' + str(bool(tokens.get('id_token'))))
print('auth_has_refresh_token=' + str(bool(tokens.get('refresh_token'))))
print('has_gmail_plugin=' + str('gmail' in cfg.lower()))
print('has_google_drive_plugin=' + str('google-drive' in cfg.lower()))
print('has_plugins_dir=' + str(Path('/root/.codex/plugins').exists()))
PY4
rm -f {shlex.quote(remote_archive)} {shlex.quote(remote_b64)}
"""

print(f"syncing_codex_to_samantha instance={instance} archive_bytes={archive_path.stat().st_size}")
print(bash(install, timeout=180).strip())

if smoke:
    smoke_command = """set -euo pipefail
rm -f /tmp/samantha-codex-sync-smoke.out /tmp/samantha-codex-sync-smoke.err
set +e
timeout 90 codex exec --skip-git-repo-check "say exactly CODEX_SYNC_OK and nothing else" >/tmp/samantha-codex-sync-smoke.out 2>/tmp/samantha-codex-sync-smoke.err
rc=$?
set -e
echo codex_smoke_rc=$rc
echo codex_smoke_stdout="$(sed -n '1p' /tmp/samantha-codex-sync-smoke.out)"
"""
    print(bash(smoke_command, timeout=140).strip())
PY
