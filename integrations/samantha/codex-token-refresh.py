#!/usr/local/lib/hermes-agent/venv/bin/python3
"""
codex-token-refresh.py — Refresh Codex (ChatGPT Pro) OAuth tokens via OpenAI endpoint.

Reads CODEX_REFRESH_TOKEN and CODEX_ACCOUNT_ID from /root/.env, calls the OpenAI token
refresh endpoint, writes a valid auth.json to /root/.codex/auth.json, and rotates the
stored refresh token (OpenAI invalidates the previous token on each use).

Run at boot (supervisor priority=2, after fix-dns) and hourly (cron).
"""
import datetime
import json
import logging
import os
import re
import subprocess
import sys
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [codex-token-refresh] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

ENV_FILE = "/root/.env"
AUTH_FILE = "/root/.codex/auth.json"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
TOKEN_URL = "https://auth.openai.com/oauth/token"
MAX_RETRIES = 3
RETRY_DELAY = 5  # seconds


def load_env(path: str) -> dict:
    env: dict = {}
    if not os.path.exists(path):
        return env
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def rotate_env(path: str, key: str, new_value: str) -> None:
    """Replace a single key=value line in the env file (atomic write)."""
    with open(path) as f:
        content = f.read()
    updated = re.sub(
        rf"^{re.escape(key)}=.*$",
        f"{key}={new_value}",
        content,
        flags=re.MULTILINE,
    )
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(updated)
    os.replace(tmp, path)


def refresh_tokens(refresh_token: str) -> dict:
    payload = json.dumps(
        {
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
            "refresh_token": refresh_token,
        }
    ).encode()

    for attempt in range(1, MAX_RETRIES + 1):
        log.info("Calling token refresh endpoint (attempt %d/%d)", attempt, MAX_RETRIES)
        result = subprocess.run(
            [
                "curl", "-sf", "-X", "POST", TOKEN_URL,
                "-H", "Content-Type: application/json",
                "--data-binary", "@-",
            ],
            input=payload,
            capture_output=True,
        )
        if result.returncode != 0:
            log.warning("curl exited %d: %s", result.returncode, result.stderr.decode()[:200])
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_DELAY)
                continue
            sys.exit(f"ERROR: curl failed after {MAX_RETRIES} attempts")

        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            log.warning("Invalid JSON response: %s", result.stdout[:200])
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_DELAY)
                continue
            sys.exit(f"ERROR: invalid JSON from token endpoint: {e}")

        if "access_token" not in data:
            error = data.get("error", "unknown")
            desc = data.get("error_description", "")
            log.warning("Token refresh failed: %s — %s", error, desc)
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_DELAY)
                continue
            sys.exit(f"ERROR: token refresh failed: {error} — {desc}")

        return data

    sys.exit("ERROR: exhausted retries")


def write_auth(data: dict, account_id: str) -> None:
    os.makedirs(os.path.dirname(AUTH_FILE), exist_ok=True)
    auth = {
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": None,
        "tokens": {
            "access_token": data["access_token"],
            "id_token": data.get("id_token", ""),
            "refresh_token": data["refresh_token"],
            "account_id": account_id,
        },
        "last_refresh": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000000Z"),
    }
    tmp = AUTH_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(auth, f, indent=2)
    os.replace(tmp, AUTH_FILE)
    log.info("Wrote %s", AUTH_FILE)


def main() -> None:
    env = load_env(ENV_FILE)

    refresh_token = env.get("CODEX_REFRESH_TOKEN", "")
    account_id = env.get("CODEX_ACCOUNT_ID", "")

    if not refresh_token:
        sys.exit(f"ERROR: CODEX_REFRESH_TOKEN not found in {ENV_FILE}")
    if not account_id:
        log.warning("CODEX_ACCOUNT_ID not set in %s — account switching may not work", ENV_FILE)

    data = refresh_tokens(refresh_token)

    write_auth(data, account_id)

    # Rotate the refresh token before it's invalidated
    rotate_env(ENV_FILE, "CODEX_REFRESH_TOKEN", data["refresh_token"])
    log.info("Token rotation complete.")


if __name__ == "__main__":
    main()
