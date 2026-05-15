#!/usr/bin/env bash
# setup-samantha.sh — Bootstrap a fresh Samantha Orgo VM from this Mac.
#
# One command, no args:
#   bash scripts/setup-samantha.sh
#
# The script runs locally, reads secrets from macOS Keychain, uploads the
# Samantha integration bundle to the VM through Orgo, and performs all VM
# mutations remotely. It must not be run as a direct VM-local installer because
# fresh VMs do not have access to macOS Keychain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INT="$REPO_ROOT/integrations/samantha"
KEYCHAIN_ACCOUNT="${SAMANTHA_KEYCHAIN_ACCOUNT:-gagan@getfoolish.com}"
COMPUTER_ID="${SAMANTHA_ORGO_COMPUTER_ID:-a7cf78dd-66a0-43d8-8f14-ba00c307acf2}"
SMOKE="${SAMANTHA_SETUP_SMOKE:-1}"

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo "    $*"; }

[[ -d "$INT" ]] || die "Missing integration bundle: $INT"

if ! command -v security >/dev/null 2>&1; then
  die "This bootstrap must run on macOS so it can read secrets from Keychain."
fi

keychain_get() {
  local service="$1"
  local account="${2:-$KEYCHAIN_ACCOUNT}"
  security find-generic-password -s "$service" -a "$account" -w 2>/dev/null || true
}

resolve_secret() {
  local env_name="$1" service="$2" account="${3:-$KEYCHAIN_ACCOUNT}"
  local value="${!env_name:-}"
  if [[ -z "$value" ]]; then
    value="$(keychain_get "$service" "$account")"
  fi
  [[ -n "$value" ]] || die "$env_name not found. Add it to Keychain service=$service account=$account or export $env_name."
  printf '%s' "$value"
}

log "0/8  Resolving local secrets from Keychain"
ORGO_API_KEY="${ORGO_API_KEY:-$(keychain_get ai.orgo.mac.api-key default)}"
[[ -n "$ORGO_API_KEY" ]] || die "ORGO_API_KEY not found in env or Keychain service=ai.orgo.mac.api-key account=default."

CODEX_REFRESH_TOKEN="$(resolve_secret CODEX_REFRESH_TOKEN codex.refresh-token)"
CODEX_ACCOUNT_ID="$(resolve_secret CODEX_ACCOUNT_ID codex.account-id)"
AITOEARN_API_KEY="$(resolve_secret AITOEARN_API_KEY aitoearn.api-key)"
COMPOSIO_API_KEY="$(resolve_secret COMPOSIO_API_KEY composio.api-key)"
step "Secrets resolved locally; values will not be printed."

ARCHIVE="$(mktemp -t samantha-integrations.XXXXXX.tgz)"
cleanup() {
  rm -f "$ARCHIVE"
}
trap cleanup EXIT

COPYFILE_DISABLE=1 tar -C "$REPO_ROOT" -czf "$ARCHIVE" integrations/samantha

export ORGO_API_KEY CODEX_REFRESH_TOKEN CODEX_ACCOUNT_ID AITOEARN_API_KEY COMPOSIO_API_KEY KEYCHAIN_ACCOUNT
python3 - "$ARCHIVE" "$COMPUTER_ID" "$SMOKE" <<'PY'
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request

archive_path = Path(sys.argv[1])
computer_id = sys.argv[2]
smoke = sys.argv[3] == "1"
api_key = os.environ["ORGO_API_KEY"]
keychain_account = os.environ.get("KEYCHAIN_ACCOUNT", "gagan@getfoolish.com")

secrets = {
    "CODEX_REFRESH_TOKEN": os.environ["CODEX_REFRESH_TOKEN"],
    "CODEX_ACCOUNT_ID": os.environ["CODEX_ACCOUNT_ID"],
    "AITOEARN_API_KEY": os.environ["AITOEARN_API_KEY"],
    "COMPOSIO_API_KEY": os.environ["COMPOSIO_API_KEY"],
}
secrets_b64 = base64.b64encode(
    "\n".join(f"{key}={base64.b64encode(value.encode()).decode()}" for key, value in secrets.items()).encode()
).decode()

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
        output = payload.get("output") or ""
        if payload.get("exit_code", 0) != 0:
            error = payload.get("error") or ""
            raise SystemExit(f"remote command failed: {output[-1200:]} {error[-1200:]}")
        return output
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
remote_archive = f"/tmp/samantha-setup-{stamp}.tgz"
remote_b64 = f"{remote_archive}.b64"

print(f"==> 1/8  Uploading integration bundle to Samantha ({instance})")
bash(f"rm -f {shlex.quote(remote_archive)} {shlex.quote(remote_b64)} && : > {shlex.quote(remote_b64)}")
encoded = base64.b64encode(archive_path.read_bytes()).decode("ascii")
for offset in range(0, len(encoded), 96_000):
    chunk = encoded[offset : offset + 96_000]
    bash(
        "python3 - <<'PY2'\n"
        "from pathlib import Path\n"
        f"Path({remote_b64!r}).open('ab').write({chunk!r}.encode('ascii'))\n"
        "PY2\n",
        timeout=60,
    )

remote = f"""set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive
BOOT="/tmp/samantha-bootstrap-{stamp}"
rm -rf /tmp/samantha-bootstrap-*
rm -rf "$BOOT"
mkdir -p "$BOOT"
python3 - <<'PY2'
import base64
from pathlib import Path
Path({remote_archive!r}).write_bytes(base64.b64decode(Path({remote_b64!r}).read_text()))
PY2
tar --warning=no-unknown-keyword --warning=no-timestamp -xzf {shlex.quote(remote_archive)} -C "$BOOT"
INT="$BOOT/integrations/samantha"
export INT

log() {{ echo "==> $*"; }}
step() {{ echo "    $*"; }}

log "2/8  Installing base VM dependencies"
if command -v apt-get >/dev/null 2>&1; then
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/lib/apt/lists/*
  missing_packages=()
  command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
  command -v git >/dev/null 2>&1 || missing_packages+=(git)
  command -v supervisord >/dev/null 2>&1 || missing_packages+=(supervisor)
  command -v cron >/dev/null 2>&1 || missing_packages+=(cron)
  command -v sshd >/dev/null 2>&1 || missing_packages+=(openssh-server)
  command -v python3 >/dev/null 2>&1 || missing_packages+=(python3)
  python3 -m venv --help >/dev/null 2>&1 || missing_packages+=(python3-venv)
  python3 -m pip --version >/dev/null 2>&1 || missing_packages+=(python3-pip)
  command -v node >/dev/null 2>&1 || missing_packages+=(nodejs)
  command -v npm >/dev/null 2>&1 || missing_packages+=(npm)
  if [[ "${{#missing_packages[@]}}" -gt 0 ]]; then
    apt-get update -qq >/dev/null
    apt-get install -y -qq ca-certificates "${{missing_packages[@]}}" >/dev/null
    apt-get clean >/dev/null 2>&1 || true
    rm -rf /var/lib/apt/lists/*
  fi
fi
mkdir -p /etc/supervisor/conf.d /root/.hermes /root/.codex /root/.claude /run/sshd
step "Base dependencies present."

log "3/8  Installing Hermes, Codex, Claude Code, and MCP packages"
if [[ ! -x /usr/local/lib/hermes-agent/venv/bin/python3 ]]; then
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
else
  step "Hermes already installed."
fi
if ! command -v codex >/dev/null 2>&1; then
  npm install -g @openai/codex >/dev/null
else
  step "Codex already installed."
fi
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code >/dev/null || true
else
  step "Claude Code already installed."
fi
npm install -g @playwright/mcp >/dev/null || true
step "Runtime packages present."

log "4/8  Fixing DNS and supervisor boot guards"
rm -f /etc/resolv.conf
printf "nameserver 8.8.8.8\\nnameserver 8.8.4.4\\n" > /etc/resolv.conf
install -m644 "$INT/fix-dns.conf" /etc/supervisor/conf.d/fix-dns.conf
step "DNS fixed and boot guard installed."

log "5/8  Seeding /root/.env from transferred Keychain secrets"
python3 - <<'PY3'
import base64
from pathlib import Path
payload = base64.b64decode({secrets_b64!r}).decode()
updates = {{}}
for line in payload.splitlines():
    key, encoded = line.split("=", 1)
    updates[key] = base64.b64decode(encoded).decode()
env_path = Path("/root/.env")
existing = {{}}
if env_path.exists():
    for line in env_path.read_text(errors="replace").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            existing[key] = value
existing.update(updates)
env_path.write_text("\\n".join(f"{{key}}={{value}}" for key, value in sorted(existing.items())) + "\\n")
env_path.chmod(0o600)
print("    Secrets written: " + ", ".join(sorted(updates)))
PY3
set -a
. /root/.env
set +a

log "6/8  Installing Hermes and Claude configs"
install -m644 "$INT/SOUL.md" /root/.hermes/SOUL.md
python3 - <<'PY4'
import os
from pathlib import Path

def render(src, dst):
    text = Path(src).read_text()
    for key, value in os.environ.items():
        text = text.replace("${{"+key+"}}", value)
    Path(dst).write_text(text)

render(os.environ["INT"] + "/config.yaml.template", "/root/.hermes/config.yaml")
render(os.environ["INT"] + "/claude_desktop_config.json.template", "/root/.claude/claude_desktop_config.json")
PY4
chmod 600 /root/.claude/claude_desktop_config.json
step "Hermes config, SOUL, and Claude MCP config deployed."

log "7/8  Installing Codex auth refresh and MCP bridges"
install -m755 "$INT/codex-token-refresh.py" /root/codex-token-refresh.py
install -m755 "$INT/restore-codex-auth.sh" /root/restore-codex-auth.sh
install -m755 "$INT/hermes-tools-mcp.py" /root/hermes-tools-mcp.py
install -m755 "$INT/aitoearn-mcp-proxy.py" /root/aitoearn-mcp-proxy.py
install -m755 "$INT/ipop-factory.py" /root/ipop-factory.py
install -m644 "$INT/restore-codex-auth.conf" /etc/supervisor/conf.d/restore-codex-auth.conf
install -m644 "$INT/ipop-factory.conf" /etc/supervisor/conf.d/ipop-factory.conf
python3 /root/ipop-factory.py init --max-workers 4 >/dev/null
CODEX_CFG="/root/.codex/config.toml"
touch "$CODEX_CFG"
python3 - <<'PY5'
import os
from pathlib import Path

cfg_path = Path("/root/.codex/config.toml")
cfg = cfg_path.read_text(errors="replace")
replace_sections = ("[mcp_servers.aitoearn]", "[mcp_servers.aitoearn.headers]")
blocks = (
    ("[mcp_servers.hermes-tools]", '[mcp_servers.hermes-tools]\\ncommand = "/root/hermes-tools-mcp.py"\\nargs = []'),
    ("[mcp_servers.playwright]", '[mcp_servers.playwright]\\ncommand = "npx"\\nargs = ["@playwright/mcp", "--headless"]'),
    ("[mcp_servers.aitoearn]", '[mcp_servers.aitoearn]\\ncommand = "/root/aitoearn-mcp-proxy.py"\\nargs = []'),
)

lines = []
skipping = False
for line in cfg.splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        skipping = stripped in replace_sections
    if skipping:
        continue
    lines.append(line)
cfg = "\\n".join(lines).rstrip() + "\\n"

for section, block in blocks:
    if section not in cfg:
        cfg = cfg.rstrip() + "\\n\\n" + block.strip() + "\\n"

cfg_path.write_text(cfg)
PY5
chmod 600 "$CODEX_CFG"
CODEX_CRON_JOB="0 * * * * /root/restore-codex-auth.sh >> /tmp/codex-token-refresh-cron.log 2>&1"
FACTORY_CRON_JOB="*/5 * * * * /root/ipop-factory.py run-once --max-workers 4 --limit 4 >> /tmp/ipop-factory-cron.log 2>&1"
( crontab -l 2>/dev/null | grep -v "restore-codex-auth" | grep -v "ipop-factory.py" || true; echo "$CODEX_CRON_JOB"; echo "$FACTORY_CRON_JOB" ) | crontab -
step "Codex refresh and MCP bridges installed."

# ---------------------------------------------------------------------------
# 6.5 Install Upwork Autopilot Chrome launcher
# ---------------------------------------------------------------------------
log "6.5/8  Install Upwork Autopilot Chrome launcher"
install -m755 "$INT/launch-upwork-chrome.sh" /root/launch-upwork-chrome.sh
step "launch-upwork-chrome.sh installed (Toronto proxy + anti-detect + persistent profile)"
step "  Launch with: tmux new -d -s upwork-chrome /root/launch-upwork-chrome.sh"
step "  Then log in via VNC (one-time), session persists at /root/.browser-sessions/upwork-autopilot"

log "8/8  Installing supervisor services and running initial refresh"
for conf in claude-bridge crond sshd ipop-factory; do
  install -m644 "$INT/$conf.conf" "/etc/supervisor/conf.d/$conf.conf"
done
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
supervisorctl restart fix-dns restore-codex-auth claude-bridge crond sshd ipop-factory >/dev/null 2>&1 || true
python3 /root/codex-token-refresh.py
if [[ {str(smoke).lower()} == true ]]; then
  set +e
  timeout 90 codex exec --skip-git-repo-check "say exactly CODEX_OK and nothing else" >/tmp/samantha-setup-codex-smoke.out 2>/tmp/samantha-setup-codex-smoke.err
  rc=$?
  set -e
  echo "    codex_smoke_rc=$rc"
  echo "    codex_smoke_stdout=$(sed -n '1p' /tmp/samantha-setup-codex-smoke.out 2>/dev/null || true)"
fi
rm -f {shlex.quote(remote_archive)} {shlex.quote(remote_b64)}
echo "Samantha setup complete."
"""
print(bash(remote, timeout=900).strip())

rotated_b64 = bash(
    """python3 - <<'PY2'
from pathlib import Path
import base64
token = ""
for line in Path('/root/.env').read_text(errors='replace').splitlines():
    if line.startswith('CODEX_REFRESH_TOKEN='):
        token = line.split('=', 1)[1]
        break
print(base64.b64encode(token.encode()).decode())
PY2
""",
    timeout=60,
).strip().splitlines()[-1]
rotated_refresh_token = base64.b64decode(rotated_b64).decode()
if rotated_refresh_token:
    subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            "codex.refresh-token",
            "-a",
            keychain_account,
            "-w",
            rotated_refresh_token,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print("Local Keychain codex.refresh-token updated after remote rotation.")
PY
