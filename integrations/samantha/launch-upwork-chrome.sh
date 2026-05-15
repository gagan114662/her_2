#!/usr/bin/env bash
# launch-upwork-chrome.sh — Launch Chrome on Samantha for Upwork Autopilot.
#
# - Routes all traffic through the Mac proxy (Canadian residential IP)
# - Uses anti-detect flags to lower Forter/Cloudflare bot signals
# - Persistent profile dir so cookies/session survive restarts
# - CDP enabled on port 9225 so the autopilot scripts can attach
#
# Idempotent: kills any prior Chrome owning the profile before launching.
set -euo pipefail

PROFILE_DIR="${UPWORK_PROFILE_DIR:-/root/.browser-sessions/upwork-autopilot}"
CDP_PORT="${UPWORK_CDP_PORT:-9225}"
PROXY="${UPWORK_PROXY:-http://127.0.0.1:8119}"
START_URL="${UPWORK_START_URL:-https://www.upwork.com/nx/find-work/best-matches}"
DISPLAY_NUM="${UPWORK_DISPLAY:-:99}"
USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

mkdir -p "$PROFILE_DIR"

# Kill any prior Chrome using this profile (idempotent)
pkill -f "user-data-dir=$PROFILE_DIR" 2>/dev/null || true
sleep 1

# Verify proxy gives a Canadian IP before launching
if ! curl -sf --max-time 8 -x "$PROXY" https://ipinfo.io > /tmp/upwork-proxy-check.json; then
  echo "ERROR: proxy $PROXY did not respond. Check supervisor: mac-tunnel + hpts + tailscale-userspace" >&2
  exit 1
fi
COUNTRY=$(python3 -c "import json; print(json.load(open('/tmp/upwork-proxy-check.json')).get('country','?'))")
CITY=$(python3 -c "import json; print(json.load(open('/tmp/upwork-proxy-check.json')).get('city','?'))")
if [[ "$COUNTRY" != "CA" ]]; then
  echo "ERROR: proxy egress is $CITY/$COUNTRY, not CA. Refusing to launch — risk of account flag." >&2
  exit 1
fi
echo "Proxy egress verified: $CITY, $COUNTRY"

# Launch Chrome — headed (visible via VNC for first-time login), with anti-detect flags
export TZ=America/Toronto
export DISPLAY="$DISPLAY_NUM"

nohup /usr/bin/google-chrome \
  --user-data-dir="$PROFILE_DIR" \
  --remote-debugging-port="$CDP_PORT" \
  --remote-debugging-address=127.0.0.1 \
  --proxy-server="$PROXY" \
  --user-agent="$USER_AGENT" \
  --window-size=1920,1080 \
  --lang=en-CA \
  --accept-lang=en-CA,en-US,en \
  --disable-blink-features=AutomationControlled \
  --disable-features=IsolateOrigins,site-per-process \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-dev-shm-usage \
  --no-first-run \
  --no-default-browser-check \
  --disable-infobars \
  --no-sandbox \
  "$START_URL" \
  > /tmp/upwork-chrome.log 2>&1 &

CHROME_PID=$!
echo "Chrome launched (pid=$CHROME_PID), waiting for CDP on :$CDP_PORT..."

for i in {1..30}; do
  if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /tmp/upwork-cdp-version.json; then
    echo "CDP ready:"
    python3 -c "import json; d=json.load(open('/tmp/upwork-cdp-version.json')); print(f\"  Browser: {d.get('Browser')}\\n  webSocketDebuggerUrl: {d.get('webSocketDebuggerUrl')}\")"
    echo "  Profile:  $PROFILE_DIR"
    echo "  Proxy:    $PROXY  ($CITY, $COUNTRY)"
    echo "  Start:    $START_URL"
    exit 0
  fi
  sleep 1
done

echo "ERROR: Chrome started but CDP endpoint never became ready on :$CDP_PORT" >&2
echo "Last 30 lines of /tmp/upwork-chrome.log:" >&2
tail -30 /tmp/upwork-chrome.log >&2 || true
exit 1
