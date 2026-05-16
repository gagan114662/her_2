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

        def normalize_opportunity_status(value):
            value = str(value or "found").strip().lower().replace("-", "_").replace(" ", "_")
            aliases = {
                "ready": "approved_to_submit",
                "approved": "approved_to_submit",
                "working": "in_progress",
                "executing": "in_progress",
            }
            value = aliases.get(value, value)
            allowed = {"found", "parsed", "rejected", "qualified", "ranked", "drafted", "approved_to_submit", "submitted", "accepted", "in_progress", "qa", "delivered", "invoiced", "paid", "closed"}
            return value if value in allowed else "found"

        def list_text(item, *keys):
            for key in keys:
                value = item.get(key)
                if isinstance(value, list):
                    return [str(v) for v in value if str(v).strip()]
                if isinstance(value, str) and value.strip():
                    return [part.strip() for part in value.split("\n") if part.strip()]
            return []

        def score_from(item):
            score = item.get("score") if isinstance(item.get("score"), dict) else {}
            reasons = score.get("reasons") if isinstance(score.get("reasons"), list) else list_text(item, "score_reasons", "reasons")
            return {
                "overall": int_from(score, "overall", int_from(item, "score", 0)),
                "payment_probability": int_from(score, "payment_probability", int_from(score, "payment_confidence", 0)),
                "time_to_cash": int_from(score, "time_to_cash", 0),
                "payout": int_from(score, "payout", int_from(score, "payout_size", 0)),
                "effort": int_from(score, "effort", int_from(score, "effort_estimate", 0)),
                "buyer_trust": int_from(score, "buyer_trust", 0),
                "requirement_clarity": int_from(score, "requirement_clarity", 0),
                "competition": int_from(score, "competition", 0),
                "capability_fit": int_from(score, "capability_fit", int_from(score, "samantha_fit", 0)),
                "account_readiness": int_from(score, "account_readiness", int_from(score, "approval_readiness", 0)),
                "risk": int_from(score, "risk", int_from(score, "execution_risk", 0)),
                "reasons": [str(reason) for reason in reasons],
            }

        def proposal_from(item):
            package = item.get("proposal_package")
            if not isinstance(package, dict):
                return None
            return {
                "buyer_problem_summary": text_from(package, "buyer_problem_summary", default=""),
                "exact_deliverables": list_text(package, "exact_deliverables", "deliverables"),
                "work_plan": list_text(package, "work_plan"),
                "milestone_split": list_text(package, "milestone_split"),
                "access_needed": list_text(package, "access_needed"),
                "proof_plan": list_text(package, "proof_plan", "proof_qa_plan"),
                "pricing_recommendation": text_from(package, "pricing_recommendation", "pricing_payment_recommendation", default=""),
                "proposal_text": text_from(package, "proposal_text", default=""),
            }

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

        ledger = []
        for index, item in enumerate(list_from(raw, "revenue_ledger", "ledger")):
            if not isinstance(item, dict):
                continue
            ledger.append({
                "id": text_from(item, "id", default=stable_id("ledger", index)),
                "opportunity_id": text_from(item, "opportunity_id", "job_id", default=None),
                "milestone_id": text_from(item, "milestone_id", default=None),
                "projected_value": float_from(item, "projected_value", 0.0),
                "quoted_value": float_from(item, "quoted_value", 0.0),
                "accepted_value": float_from(item, "accepted_value", 0.0),
                "invoiced_value": float_from(item, "invoiced_value", 0.0),
                "pending_payment": float_from(item, "pending_payment", 0.0),
                "platform_fees": float_from(item, "platform_fees", 0.0),
                "net_received": float_from(item, "net_received", 0.0),
                "currency": text_from(item, "currency", default=text_from(raw, "currency", default="USD")).upper(),
                "payment_status": normalize_payment_status(item.get("payment_status") or item.get("status")),
                "proof_url": text_from(item, "proof_url", "payment_proof_url", default=None),
                "blocker_reason": text_from(item, "blocker_reason", "blocker", default=None),
                "updated_at": text_from(item, "updated_at", "timestamp", default=None),
            })

        opportunities = []
        for index, item in enumerate(list_from(raw, "opportunities", "remote_jobs", "leads")):
            if not isinstance(item, dict):
                continue
            opportunity_id = text_from(item, "id", "job_id", "opportunity_id", default=stable_id("opp", text_from(item, "source_url", "url", default=""), index))
            payment = next((entry for entry in ledger if entry.get("opportunity_id") == opportunity_id), None)
            opportunities.append({
                "id": opportunity_id,
                "source": text_from(item, "source", default="unknown"),
                "source_url": text_from(item, "source_url", "url", default=""),
                "platform": text_from(item, "platform", default="unknown"),
                "buyer": text_from(item, "buyer", "company", "client", default="unknown buyer"),
                "title": text_from(item, "title", default=f"Opportunity {index + 1}"),
                "raw_requirement": text_from(item, "raw_requirement", "description", "requirement", default=""),
                "normalized_deliverables": list_text(item, "normalized_deliverables", "deliverables"),
                "acceptance_criteria": list_text(item, "acceptance_criteria"),
                "budget": float_from(item, "budget", 0.0),
                "currency": text_from(item, "currency", default=text_from(raw, "currency", default="USD")).upper(),
                "urgency": text_from(item, "urgency", default="unknown"),
                "contact_route": text_from(item, "contact_route", default="platform"),
                "required_tools": list_text(item, "required_tools", "tech_stack"),
                "account_readiness": text_from(item, "account_readiness", default="unknown"),
                "risk_flags": list_text(item, "risk_flags"),
                "status": normalize_opportunity_status(item.get("status")),
                "score": score_from(item),
                "proposal_package": proposal_from(item),
                "execution_plan": list_text(item, "execution_plan"),
                "payment": payment,
                "evidence": list_text(item, "evidence"),
                "updated_at": text_from(item, "updated_at", default=None),
            })

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
        found_opportunities = int_from(summary_raw, "found_opportunities", len(opportunities))
        qualified_opportunities = int_from(summary_raw, "qualified_opportunities", sum(1 for item in opportunities if item["status"] in {"qualified", "ranked", "drafted", "approved_to_submit", "submitted", "accepted", "in_progress", "qa", "delivered", "invoiced", "paid"}))
        drafted_opportunities = int_from(summary_raw, "drafted_opportunities", sum(1 for item in opportunities if item["status"] in {"drafted", "approved_to_submit", "submitted", "accepted", "in_progress", "qa", "delivered", "invoiced", "paid"}))
        approved_to_submit = int_from(summary_raw, "approved_to_submit", sum(1 for item in opportunities if item["status"] == "approved_to_submit"))
        queued_milestones = int_from(summary_raw, "queued_milestones", sum(1 for item in milestones if item["stage"] in {"demand", "proof", "paid"}))
        running_milestones = int_from(summary_raw, "running_milestones", sum(1 for item in milestones if item["stage"] == "executing"))
        qa_blocked = int_from(summary_raw, "qa_blocked", sum(1 for item in milestones if item["qa_status"] in {"failed", "needs_human"} or item["stage"] == "blocked"))
        ready_to_deliver = int_from(summary_raw, "ready_to_deliver", sum(1 for item in milestones if item["stage"] == "delivery" and item["qa_status"] == "passed"))
        revenue_at_risk = float_from(summary_raw, "revenue_at_risk", sum(item["budget"] for item in milestones if item["stage"] not in {"delivery"}))
        events = []
        for index, item in enumerate(list_from(raw, "events", "audit_events")):
            if not isinstance(item, dict):
                continue
            events.append({
                "id": text_from(item, "id", default=stable_id("event", index, item.get("timestamp"))),
                "timestamp": text_from(item, "timestamp", "ts", default=now),
                "subject_id": text_from(item, "subject_id", "opportunity_id", "job_id", "milestone_id", default="factory"),
                "action": text_from(item, "action", default="logged"),
                "evidence": text_from(item, "evidence", "reason", default=""),
            })
        approval_rules = []
        for index, item in enumerate(list_from(raw, "approval_rules")):
            if not isinstance(item, dict):
                continue
            approval_rules.append({
                "id": text_from(item, "id", default=stable_id("rule", index)),
                "source": text_from(item, "source", default="*"),
                "platform": text_from(item, "platform", default="*"),
                "max_risk": int_from(item, "max_risk", 35),
                "max_quoted_value": float_from(item, "max_quoted_value", 0.0),
                "allowed_actions": list_text(item, "allowed_actions"),
                "enabled": bool(item.get("enabled", True)),
                "created_at": text_from(item, "created_at", default=None),
            })

        print(json.dumps({
            "state_path": str(state_path),
            "generated_at": text_from(raw, "generated_at", default=now),
            "summary": {
                "active_workers": active_workers,
                "max_workers": max_workers,
                "found_opportunities": found_opportunities,
                "qualified_opportunities": qualified_opportunities,
                "drafted_opportunities": drafted_opportunities,
                "approved_to_submit": approved_to_submit,
                "queued_milestones": queued_milestones,
                "running_milestones": running_milestones,
                "qa_blocked": qa_blocked,
                "ready_to_deliver": ready_to_deliver,
                "revenue_at_risk": revenue_at_risk,
                "currency": text_from(raw, "currency", default="USD").upper(),
            },
            "opportunities": opportunities,
            "queues": queues,
            "workers": workers,
            "milestones": milestones,
            "qa_reviews": qa_reviews,
            "payments": payments,
            "revenue_ledger": ledger,
            "events": events,
            "approval_rules": approval_rules,
        }))
        """##
    }
}
