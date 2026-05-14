import Foundation

final class RevenueBrowserService: @unchecked Sendable {
    private let transport: any RemoteTransport

    init(transport: any RemoteTransport) {
        self.transport = transport
    }

    func loadDashboard(connection: ConnectionProfile) async throws -> RevenueDashboard {
        let script = try RemotePythonScript.wrap(
            RevenueDashboardRequest(
                hermesHome: connection.remoteHermesHomePath,
                profileName: connection.resolvedHermesProfileName
            ),
            body: Self.dashboardScript
        )

        return try await transport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: RevenueDashboard.self
        )
    }

    func bootstrap(connection: ConnectionProfile) async throws -> RevenueSetupResult {
        let script = try RemotePythonScript.wrap(
            RevenueDashboardRequest(
                hermesHome: connection.remoteHermesHomePath,
                profileName: connection.resolvedHermesProfileName
            ),
            body: Self.bootstrapScript
        )

        return try await transport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: RevenueSetupResult.self
        )
    }
}

private struct RevenueDashboardRequest: Encodable {
    let hermesHome: String
    let profileName: String

    enum CodingKeys: String, CodingKey {
        case hermesHome = "hermes_home"
        case profileName = "profile_name"
    }
}

extension RevenueBrowserService {
    static var dashboardScript: String {
        ##"""
        import datetime as _dt
        import json
        import os
        import pathlib
        import subprocess
        import uuid

        def read_json(path):
            if not path.exists():
                return {}
            try:
                return json.loads(path.read_text())
            except Exception:
                return {}

        def parse_time(value):
            if value is None:
                return None
            if isinstance(value, (int, float)):
                return _dt.datetime.fromtimestamp(float(value), tz=_dt.timezone.utc)
            text = str(value).strip()
            if not text:
                return None
            if text.endswith("Z"):
                text = text[:-1] + "+00:00"
            try:
                parsed = _dt.datetime.fromisoformat(text)
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=_dt.timezone.utc)
                return parsed.astimezone(_dt.timezone.utc)
            except Exception:
                return None

        def iso(value):
            parsed = parse_time(value)
            return parsed.isoformat().replace("+00:00", "Z") if parsed else None

        def amount_from(item):
            for key in ("amount", "revenue", "earned", "total", "value"):
                try:
                    if item.get(key) is not None:
                        return float(item.get(key))
                except Exception:
                    continue
            return 0.0

        def text_from(item, *keys, default=""):
            for key in keys:
                value = item.get(key)
                if value is not None and str(value).strip():
                    return str(value).strip()
            return default

        def list_from(data, *keys):
            for key in keys:
                value = data.get(key)
                if isinstance(value, list):
                    return value
            if isinstance(data, list):
                return data
            return []

        def command_ok(args):
            try:
                result = subprocess.run(args, capture_output=True, text=True, timeout=4)
                return result.returncode == 0, (result.stdout or "").strip()
            except Exception:
                return False, ""

        home = pathlib.Path.home()
        candidates = [
            pathlib.Path("/home/user/revenue-log.json"),
            home / "revenue-log.json",
            home / ".hermes" / "revenue-log.json",
        ]
        log_path = next((path for path in candidates if path.exists()), candidates[0])
        raw = read_json(log_path)

        events_raw = list_from(raw, "events", "entries", "payments", "posts", "runs")
        workflows_raw = list_from(raw, "workflows")
        reviews_raw = list_from(raw, "reviews")
        fleet_raw = list_from(raw, "fleet", "computers", "vms")

        now = _dt.datetime.now(_dt.timezone.utc)
        start_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
        start_week = start_day - _dt.timedelta(days=start_day.weekday())
        start_month = start_day.replace(day=1)
        daily_totals = {}
        workflows = {}
        events = []
        currency = text_from(raw, "currency", default="USD").upper()

        for index, item in enumerate(events_raw):
            if not isinstance(item, dict):
                continue
            timestamp = parse_time(item.get("timestamp") or item.get("created_at") or item.get("date"))
            workflow = text_from(item, "workflow", "workflow_name", "source", default="Unassigned")
            event_currency = text_from(item, "currency", default=currency).upper()
            amount = amount_from(item)
            event_id = text_from(item, "id", "event_id", "payment_id", default=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{workflow}:{index}:{timestamp}:{amount}")))
            events.append({
                "id": event_id,
                "timestamp": timestamp.isoformat().replace("+00:00", "Z") if timestamp else None,
                "workflow": workflow,
                "platform": text_from(item, "platform", "channel", default=None),
                "amount": amount,
                "currency": event_currency,
                "action": text_from(item, "action", "action_taken", "type", default=None),
                "post_url": text_from(item, "post_url", "url", default=None),
                "flow_id": text_from(item, "flowId", "flow_id", default=None),
                "verification_url": text_from(item, "verification_url", "live_url", default=None),
                "error": text_from(item, "error", default=None),
            })
            if timestamp:
                daily_totals[timestamp.date().isoformat()] = daily_totals.get(timestamp.date().isoformat(), 0.0) + amount
            summary = workflows.setdefault(workflow, {
                "id": workflow.lower().replace(" ", "-"),
                "name": workflow,
                "revenue": 0.0,
                "currency": event_currency,
                "last_event_at": None,
                "workflow_url": text_from(item, "workflow_url", "n8n_url", default=None),
                "verification_url": text_from(item, "verification_url", "post_url", "url", default=None),
                "status": "active" if not item.get("error") else "attention",
            })
            summary["revenue"] += amount
            if timestamp and (summary["last_event_at"] is None or timestamp > parse_time(summary["last_event_at"])):
                summary["last_event_at"] = timestamp.isoformat().replace("+00:00", "Z")

        for index, item in enumerate(workflows_raw):
            if not isinstance(item, dict):
                continue
            name = text_from(item, "name", "workflow", default=f"Workflow {index + 1}")
            existing = workflows.setdefault(name, {
                "id": text_from(item, "id", default=name.lower().replace(" ", "-")),
                "name": name,
                "revenue": 0.0,
                "currency": text_from(item, "currency", default=currency).upper(),
                "last_event_at": iso(item.get("deployed_at") or item.get("last_event_at")),
                "workflow_url": text_from(item, "workflow_url", "n8n_url", default=None),
                "verification_url": text_from(item, "verification_url", "live_verification_url", default=None),
                "status": text_from(item, "status", default="active"),
            })
            existing["workflow_url"] = existing["workflow_url"] or text_from(item, "workflow_url", "n8n_url", default=None)
            existing["verification_url"] = existing["verification_url"] or text_from(item, "verification_url", "live_verification_url", default=None)

        def total_since(start):
            total = 0.0
            for event in events:
                timestamp = parse_time(event.get("timestamp"))
                if timestamp and timestamp >= start:
                    total += event.get("amount", 0.0)
            return total

        cron_ok, cron_out = command_ok(["/bin/sh", "-lc", "crontab -l 2>/dev/null || true"])
        n8n_health, _ = command_ok(["/bin/sh", "-lc", "curl -fsS http://localhost:5678/healthz >/dev/null"])
        # Use process/supervisor checks — systemd is not available in container environments
        n8n_active, _ = command_ok(["/bin/sh", "-lc", "pgrep -f 'node.*n8n' >/dev/null 2>&1 || supervisorctl status n8n 2>/dev/null | grep -q RUNNING"])
        n8n_enabled, _ = command_ok(["/bin/sh", "-lc", "supervisorctl status n8n 2>/dev/null | grep -qE 'RUNNING|STARTING' || crontab -l 2>/dev/null | grep -q n8n"])
        cloudflared_enabled, _ = command_ok(["/bin/sh", "-lc", "pgrep -f cloudflared >/dev/null 2>&1 || supervisorctl status cloudflared 2>/dev/null | grep -q RUNNING"])

        env_text = ""
        for env_candidate in [pathlib.Path.home() / ".hermes" / ".env", pathlib.Path("/etc/environment")]:
            try:
                env_text = env_candidate.read_text()
                break
            except Exception:
                pass

        def env_value(key):
            prefix = key + "="
            for line in env_text.splitlines():
                if line.startswith(prefix):
                    return line[len(prefix):].strip().strip('"')
            return None

        account_count = 0
        accounts = raw.get("aitoearn_accounts")
        if isinstance(accounts, list):
            account_count = len([item for item in accounts if isinstance(item, dict) and item.get("status") == "active"])

        print(json.dumps({
            "log_path": str(log_path),
            "generated_at": now.isoformat().replace("+00:00", "Z"),
            "totals": {
                "today": total_since(start_day),
                "week": total_since(start_week),
                "month": total_since(start_month),
                "all_time": sum(event.get("amount", 0.0) for event in events),
                "currency": currency,
                "daily": [{"date": day, "amount": amount} for day, amount in sorted(daily_totals.items())[-30:]],
            },
            "workflows": sorted(workflows.values(), key=lambda item: item.get("revenue", 0.0), reverse=True),
            "events": sorted(events, key=lambda item: item.get("timestamp") or "", reverse=True)[:100],
            "reviews": [{
                "id": text_from(item, "id", default=str(index)),
                "timestamp": iso(item.get("timestamp") or item.get("created_at")),
                "workflow": text_from(item, "workflow", default="Unassigned"),
                "verdict": text_from(item, "verdict", default="review"),
                "action_taken": text_from(item, "action_taken", "action", default=""),
                "revenue": amount_from(item),
                "clicks": item.get("clicks"),
                "conversions": item.get("conversions"),
            } for index, item in enumerate(reviews_raw) if isinstance(item, dict)],
            "fleet": [{
                "id": text_from(item, "id", "computer_id", default=text_from(item, "name", default=str(index))),
                "name": text_from(item, "name", default=f"agent-{index + 1}"),
                "purpose": text_from(item, "purpose", "tag", default="revenue"),
                "status": text_from(item, "status", default="unknown"),
                "uptime": text_from(item, "uptime", default="unknown"),
                "revenue": amount_from(item),
                "currency": text_from(item, "currency", default=currency).upper(),
                "failure_count": int(item.get("failure_count") or item.get("failures") or 0),
            } for index, item in enumerate(fleet_raw) if isinstance(item, dict)],
            "setup": {
                "mission_exists": pathlib.Path("/home/user/mission.md").exists(),
                "revenue_log_exists": log_path.exists(),
                "review_agent_exists": pathlib.Path("/home/user/review-agent.sh").exists(),
                "n8n_healthy": n8n_health,
                "n8n_service_active": n8n_active,
                "n8n_service_enabled": n8n_enabled,
                "cloudflared_enabled": cloudflared_enabled,
                "public_url": env_value("VM_PUBLIC_URL"),
                "cron_entries": [line for line in cron_out.splitlines() if "hermes" in line.lower() or "claude" in line.lower() or "review-agent" in line.lower() or "revenue-agent" in line.lower()],
                "aitoearn_configured": bool(env_value("AITOEARN_API_KEY")),
                "social_accounts_connected": account_count > 0,
            },
        }))
        """##
    }

    static var bootstrapScript: String {
        ##"""
        import json
        import pathlib
        import secrets
        import subprocess

        steps = []
        errors = []
        mission_path = pathlib.Path("/home/user/mission.md")
        revenue_log_path = pathlib.Path("/home/user/revenue-log.json")
        review_agent_path = pathlib.Path("/home/user/review-agent.sh")
        revenue_agent_path = pathlib.Path("/home/user/revenue-agent.sh")

        def write_if_missing(path, text, mode=None):
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                if not path.exists():
                    path.write_text(text)
                    if mode is not None:
                        path.chmod(mode)
                    return True
                return False
            except Exception as exc:
                errors.append(f"Failed to write {path}: {exc}")
                return False

        mission_written = write_if_missing(mission_path, """# Samantha revenue mission

        Goal: Generate recurring digital revenue autonomously.
        Niche: AI automation for operators and small businesses.
        Brand name: Samantha Revenue Lab.
        Revenue target: 1000 USD/month.
        Constraints: prefer digital products, affiliate content, and B2B workflow automations; log every external action and URL to /home/user/revenue-log.json; ask before spending money or creating more than 5 VMs.
        """)
        steps.append("mission_written" if mission_written else "mission_present")

        if write_if_missing(revenue_log_path, '{"currency":"USD","events":[],"workflows":[],"reviews":[],"fleet":[]}' + "\n", 0o600):
            steps.append("revenue_log_created")
        else:
            steps.append("revenue_log_present")

        revenue_script = """#!/usr/bin/env bash
        set -euo pipefail
        LOG=/home/user/revenue-log.json
        MISSION=/home/user/mission.md
        PROMPT="$(cat "$MISSION")

        Read /home/user/revenue-log.json, choose the next non-duplicate revenue action, execute one real external action if credentials are available, and append a JSON entry with timestamp, workflow name, action taken, deployed asset, verification URL, platform, post URL, flowId, and errors. Prefer AiToEarn publishing, n8n workflow deployment, Stripe/Gumroad product creation, or Upwork proposal workflows when their accounts are configured."

        if command -v hermes >/dev/null 2>&1; then
          ANTHROPIC_API_KEY="\${ANTHROPIC_API_KEY:-bridge-passthrough}" hermes -z "$PROMPT"
        elif command -v claude >/dev/null 2>&1; then
          claude -p "$PROMPT"
        else
          python3 - <<'PY'
        import datetime, json, pathlib
        path = pathlib.Path("/home/user/revenue-log.json")
        data = json.loads(path.read_text())
        data.setdefault("events", []).append({
          "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
          "workflow": "bootstrap",
          "action": "Hermes/Claude CLI missing; no external action attempted",
          "amount": 0,
          "currency": data.get("currency", "USD"),
          "error": "Install hermes or claude on the VM to run the revenue loop"
        })
        path.write_text(json.dumps(data, indent=2) + "\\n")
        PY
        fi
        """
        if write_if_missing(revenue_agent_path, revenue_script, 0o755):
            steps.append("revenue_agent_written")
        else:
            steps.append("revenue_agent_present")

        review_script = """#!/usr/bin/env bash
        set -euo pipefail
        PROMPT="Read /home/user/revenue-log.json. Add or update a reviews array with metrics pulled, verdict keep/kill/improve, and action taken. If a workflow made 0 USD in its first week, rewrite its n8n workflow JSON with a different strategy; if it made revenue, create a second A/B variation. Append all changes to the log."
        if command -v hermes >/dev/null 2>&1; then
          ANTHROPIC_API_KEY="\${ANTHROPIC_API_KEY:-bridge-passthrough}" hermes -z "$PROMPT"
        elif command -v claude >/dev/null 2>&1; then
          claude -p "$PROMPT"
        fi
        """
        if write_if_missing(review_agent_path, review_script, 0o755):
            steps.append("review_agent_written")
        else:
            steps.append("review_agent_present")

        try:
            current = subprocess.run(["/bin/sh", "-lc", "crontab -l 2>/dev/null || true"], capture_output=True, text=True, timeout=8).stdout
            lines = [line for line in current.splitlines() if line.strip()]
            desired = [
                "0 7 * * * /home/user/revenue-agent.sh >> /home/user/revenue-agent.log 2>&1",
                "0 8 * * * /home/user/revenue-agent.sh --content-loop >> /home/user/revenue-agent.log 2>&1",
                "0 9 * * 0 /home/user/review-agent.sh >> /home/user/review-agent.log 2>&1",
            ]
            changed = False
            for line in desired:
                if line not in lines:
                    lines.append(line)
                    changed = True
            if changed:
                subprocess.run(["crontab", "-"], input="\n".join(lines) + "\n", text=True, check=True, timeout=8)
                steps.append("crontab_updated")
            else:
                steps.append("crontab_present")
        except Exception as exc:
            errors.append(f"Failed to install revenue crons: {exc}")

        try:
            env_path = pathlib.Path.home() / ".hermes" / ".env"
            env_path.parent.mkdir(parents=True, exist_ok=True)
            env_text = env_path.read_text() if env_path.exists() else ""
            additions = []
            if "N8N_API_KEY=" not in env_text:
                additions.append(f'N8N_API_KEY="{secrets.token_urlsafe(32)}"')
            if "REVENUE_LOG_PATH=" not in env_text:
                additions.append('REVENUE_LOG_PATH="/home/user/revenue-log.json"')
            if additions:
                with env_path.open("a") as fh:
                    if env_text and not env_text.endswith("\n"):
                        fh.write("\n")
                    fh.write("\n".join(additions) + "\n")
                steps.append("environment_updated")
            else:
                steps.append("environment_present")
        except Exception as exc:
            errors.append(f"Failed to update ~/.hermes/.env: {exc}")

        print(json.dumps({
            "success": len(errors) == 0,
            "steps_done": steps,
            "errors": errors,
            "revenue_log_path": str(revenue_log_path),
            "mission_path": str(mission_path),
        }))
        """##
    }
}
