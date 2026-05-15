import Foundation

final class FactoryBrowserService: @unchecked Sendable {
    private let transport: any RemoteTransport

    init(transport: any RemoteTransport) {
        self.transport = transport
    }

    func loadDashboard(connection: ConnectionProfile) async throws -> FactoryDashboard {
        let script = try RemotePythonScript.wrap(
            FactoryDashboardRequest(
                hermesHome: connection.remoteHermesHomePath,
                profileName: connection.resolvedHermesProfileName
            ),
            body: Self.dashboardScript
        )

        return try await transport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: FactoryDashboard.self
        )
    }
}

private struct FactoryDashboardRequest: Encodable {
    let hermesHome: String
    let profileName: String

    enum CodingKeys: String, CodingKey {
        case hermesHome = "hermes_home"
        case profileName = "profile_name"
    }
}

extension FactoryBrowserService {
    static var dashboardScript: String {
        ##"""
        import datetime as _dt
        import json
        import pathlib
        import uuid

        def read_json(path):
            if not path.exists():
                return {}
            try:
                return json.loads(path.read_text())
            except Exception:
                return {}

        def list_from(data, *keys):
            for key in keys:
                value = data.get(key)
                if isinstance(value, list):
                    return value
            return []

        def text_from(item, *keys, default=""):
            for key in keys:
                value = item.get(key)
                if value is not None and str(value).strip():
                    return str(value).strip()
            return default

        def int_from(item, key, default=0):
            try:
                return int(item.get(key, default))
            except Exception:
                return default

        def float_from(item, key, default=0.0):
            try:
                return float(item.get(key, default))
            except Exception:
                return default

        def stable_id(prefix, *parts):
            return f"{prefix}_{uuid.uuid5(uuid.NAMESPACE_URL, ':'.join(str(part) for part in parts))}"

        def normalize_stage(value, default="demand"):
            value = str(value or default).strip().lower().replace("-", "_").replace(" ", "_")
            aliases = {
                "lead": "demand",
                "leads": "demand",
                "scouting": "demand",
                "qualifying": "demand",
                "proofing": "proof",
                "proof_of_competence": "proof",
                "work": "executing",
                "running": "executing",
                "review": "qa",
                "ready": "delivery",
                "ready_to_deliver": "delivery",
            }
            value = aliases.get(value, value)
            if value not in {"demand", "proof", "paid", "executing", "qa", "delivery", "blocked"}:
                return default
            return value

        def normalize_worker_role(value):
            value = str(value or "fulfillment").strip().lower().replace("-", "_").replace(" ", "_")
            aliases = {
                "lead": "scanner",
                "lead_qualifier": "qualifier",
                "proof_of_competence": "proof",
                "worker": "fulfillment",
                "executor": "fulfillment",
                "reviewer": "qa",
                "packager": "delivery",
                "billing": "payment",
            }
            value = aliases.get(value, value)
            if value not in {"scanner", "qualifier", "proof", "fulfillment", "qa", "delivery", "payment"}:
                return "fulfillment"
            return value

        def normalize_worker_status(value):
            value = str(value or "idle").strip().lower().replace("-", "_").replace(" ", "_")
            aliases = {
                "active": "running",
                "working": "running",
                "paused": "waiting",
                "needs_input": "waiting",
                "error": "failed",
            }
            value = aliases.get(value, value)
            if value not in {"idle", "queued", "running", "waiting", "blocked", "failed"}:
                return "idle"
            return value

        def normalize_qa_status(value):
            value = str(value or "not_started").strip().lower().replace("-", "_").replace(" ", "_")
            aliases = {
                "none": "not_started",
                "new": "not_started",
                "reviewing": "pending",
                "ok": "passed",
                "pass": "passed",
                "fail": "failed",
                "human": "needs_human",
                "approval": "needs_human",
            }
            value = aliases.get(value, value)
            if value not in {"not_started", "pending", "passed", "failed", "needs_human"}:
                return "not_started"
            return value

        def normalize_payment_status(value):
            value = str(value or "unpaid").strip().lower().replace("-", "_").replace(" ", "_")
            aliases = {
                "deposit": "deposit_paid",
                "partially_paid": "deposit_paid",
                "succeeded": "paid",
                "complete": "paid",
                "chargeback": "disputed",
            }
            value = aliases.get(value, value)
            if value not in {"unpaid", "deposit_paid", "paid", "disputed", "refunded"}:
                return "unpaid"
            return value

        now = _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")
        home = pathlib.Path.home()
        hermes_home = pathlib.Path(request.get("hermes_home") or (home / ".hermes"))
        candidates = [
            home / "ipop-factory.json",
            home / ".hermes" / "ipop-factory.json",
            hermes_home / "ipop-factory.json",
            home / "revenue-factory.json",
            home / ".hermes" / "revenue-factory.json",
        ]
        state_path = next((path for path in candidates if path.exists()), candidates[0])
        raw = read_json(state_path)

        milestones = []
        for index, item in enumerate(list_from(raw, "milestones", "jobs", "opportunities", "work_items")):
            if not isinstance(item, dict):
                continue
            source = text_from(item, "source", "platform", default="unknown")
            signal = text_from(item, "client_signal", "client_need", "title", "brief", default=f"Opportunity {index + 1}")
            offer = text_from(item, "offer", "service", "category", default="Agent milestone")
            milestone_id = text_from(item, "id", "job_id", "milestone_id", default=stable_id("ms", source, signal, index))
            currency = text_from(item, "currency", default=text_from(raw, "currency", default="USD")).upper()
            artifacts = item.get("artifact_urls") or item.get("artifacts") or []
            if not isinstance(artifacts, list):
                artifacts = [str(artifacts)]
            proof_required = item.get("proof_required") or item.get("proof") or []
            if not isinstance(proof_required, list):
                proof_required = [str(proof_required)]
            milestones.append({
                "id": milestone_id,
                "source": source,
                "client_signal": signal,
                "offer": offer,
                "budget": float_from(item, "budget", float_from(item, "amount", 0.0)),
                "currency": currency,
                "stage": normalize_stage(item.get("stage") or item.get("status")),
                "assigned_worker_id": text_from(item, "assigned_worker_id", "worker_id", default=None),
                "qa_status": normalize_qa_status(item.get("qa_status")),
                "payment_status": normalize_payment_status(item.get("payment_status")),
                "proof_required": [str(value) for value in proof_required],
                "artifact_urls": [str(value) for value in artifacts],
                "updated_at": text_from(item, "updated_at", "last_event_at", default=None),
            })

        workers = []
        for index, item in enumerate(list_from(raw, "workers", "agents", "sessions")):
            if not isinstance(item, dict):
                continue
            name = text_from(item, "name", "agent", default=f"Worker {index + 1}")
            worker_id = text_from(item, "id", "worker_id", "session_id", default=stable_id("worker", name, index))
            workers.append({
                "id": worker_id,
                "name": name,
                "role": normalize_worker_role(item.get("role") or item.get("type")),
                "status": normalize_worker_status(item.get("status")),
                "current_milestone_id": text_from(item, "current_milestone_id", "milestone_id", "job_id", default=None),
                "started_at": text_from(item, "started_at", "created_at", default=None),
                "workspace_url": text_from(item, "workspace_url", "session_url", "url", default=None),
                "proof_url": text_from(item, "proof_url", "artifact_url", default=None),
                "failure_count": int_from(item, "failure_count", 0),
            })

        qa_reviews = []
        for index, item in enumerate(list_from(raw, "qa_reviews", "reviews", "qa")):
            if not isinstance(item, dict):
                continue
            milestone_id = text_from(item, "milestone_id", "job_id", default=stable_id("ms", "qa", index))
            qa_reviews.append({
                "id": text_from(item, "id", "review_id", default=stable_id("qa", milestone_id, index)),
                "milestone_id": milestone_id,
                "reviewer": text_from(item, "reviewer", "agent", default="QA agent"),
                "status": normalize_qa_status(item.get("status") or item.get("verdict")),
                "checks_passed": int_from(item, "checks_passed", 0),
                "checks_total": int_from(item, "checks_total", int_from(item, "total", 0)),
                "notes": text_from(item, "notes", "summary", default=""),
                "updated_at": text_from(item, "updated_at", "timestamp", default=None),
            })

        payments = []
        for index, item in enumerate(list_from(raw, "payments", "stripe", "billing")):
            if not isinstance(item, dict):
                continue
            milestone_id = text_from(item, "milestone_id", "job_id", default=stable_id("ms", "payment", index))
            payments.append({
                "id": text_from(item, "id", "payment_id", default=stable_id("pay", milestone_id, index)),
                "milestone_id": milestone_id,
                "stripe_object_id": text_from(item, "stripe_object_id", "stripe_id", "checkout_session_id", default=None),
                "amount": float_from(item, "amount", 0.0),
                "currency": text_from(item, "currency", default=text_from(raw, "currency", default="USD")).upper(),
                "status": normalize_payment_status(item.get("status") or item.get("payment_status")),
                "updated_at": text_from(item, "updated_at", "timestamp", default=None),
            })

        stage_order = ["demand", "proof", "paid", "executing", "qa", "delivery", "blocked"]
        queue_overrides = {
            str(item.get("stage") or item.get("id") or "").lower(): item
            for item in list_from(raw, "queues")
            if isinstance(item, dict)
        }
        queues = []
        for stage in stage_order:
            override = queue_overrides.get(stage, {})
            count = int_from(override, "count", sum(1 for item in milestones if item["stage"] == stage))
            queues.append({
                "id": text_from(override, "id", default=stage),
                "name": text_from(override, "name", default=stage.replace("_", " ").title()),
                "stage": stage,
                "count": count,
                "oldest_age_minutes": override.get("oldest_age_minutes"),
                "sla_minutes": override.get("sla_minutes"),
            })

        summary_raw = raw.get("summary") if isinstance(raw.get("summary"), dict) else {}
        active_workers = int_from(summary_raw, "active_workers", sum(1 for worker in workers if worker["status"] == "running"))
        max_workers = int_from(summary_raw, "max_workers", max(active_workers, int_from(raw, "max_workers", 10)))
        queued_milestones = int_from(summary_raw, "queued_milestones", sum(1 for item in milestones if item["stage"] in {"demand", "proof", "paid"}))
        running_milestones = int_from(summary_raw, "running_milestones", sum(1 for item in milestones if item["stage"] == "executing"))
        qa_blocked = int_from(summary_raw, "qa_blocked", sum(1 for item in milestones if item["qa_status"] in {"failed", "needs_human"} or item["stage"] == "blocked"))
        ready_to_deliver = int_from(summary_raw, "ready_to_deliver", sum(1 for item in milestones if item["stage"] == "delivery" and item["qa_status"] == "passed"))
        revenue_at_risk = float_from(summary_raw, "revenue_at_risk", sum(item["budget"] for item in milestones if item["stage"] not in {"delivery"}))

        print(json.dumps({
            "state_path": str(state_path),
            "generated_at": text_from(raw, "generated_at", default=now),
            "summary": {
                "active_workers": active_workers,
                "max_workers": max_workers,
                "queued_milestones": queued_milestones,
                "running_milestones": running_milestones,
                "qa_blocked": qa_blocked,
                "ready_to_deliver": ready_to_deliver,
                "revenue_at_risk": revenue_at_risk,
                "currency": text_from(raw, "currency", default="USD").upper(),
            },
            "queues": queues,
            "workers": workers,
            "milestones": milestones,
            "qa_reviews": qa_reviews,
            "payments": payments,
        }))
        """##
    }
}
