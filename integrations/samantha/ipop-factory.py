#!/usr/bin/env python3
"""File-backed iPOP/Samantha paid remote-work factory.

This runtime borrows the JustHireMe shape: discover leads, normalize them,
quality-gate, score with visible reasons, generate material, and keep an audit
event stream. Samantha adds the execution layer: accepted work is promoted into
parallel factory milestones, while any external submission stays approval-gated.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from typing import Any


DEFAULT_STATE_PATH = pathlib.Path(os.environ.get("IPOP_FACTORY_STATE", "/root/ipop-factory.json"))
DEFAULT_ARTIFACT_DIR = pathlib.Path(os.environ.get("IPOP_FACTORY_ARTIFACT_DIR", "/root/ipop-factory-artifacts"))
DEFAULT_MAX_WORKERS = int(os.environ.get("IPOP_FACTORY_MAX_WORKERS", "4"))
REMOTEOK_API = "https://remoteok.com/api"
DEFAULT_RSS_SOURCES = (
    "https://www.reddit.com/r/forhire/.rss",
    "https://www.reddit.com/r/slavelabour/.rss",
)

OPPORTUNITY_STATUSES = {
    "found", "parsed", "rejected", "qualified", "ranked", "drafted",
    "approved_to_submit", "submitted", "accepted", "in_progress", "qa",
    "delivered", "invoiced", "paid", "closed",
}

EXECUTABLE_TERMS = (
    "automation", "ai", "agent", "workflow", "n8n", "zapier", "make.com",
    "stripe", "wordpress", "shopify", "webflow", "python", "javascript",
    "typescript", "react", "next.js", "api", "integration", "scrape",
    "data", "dashboard", "qa", "testing", "research", "gmail", "sheets",
    "airtable", "notion", "hubspot", "crm", "landing page",
)

CLEAR_WORK_TERMS = (
    "fix", "build", "create", "implement", "debug", "integrate", "automate",
    "workflow", "webhook", "scrape", "clean", "migrate", "set up", "setup",
    "develop", "test", "qa", "repair", "configure", "deploy",
)

HARD_REJECT_FLAGS = {
    "unpaid_trial": ("unpaid trial", "free trial", "test task unpaid", "work for exposure", "equity only"),
    "fake_payment": ("fake check", "cashier check", "deposit this check", "overpayment"),
    "upfront_fee": ("upfront fee", "registration fee", "pay to apply", "buy starter kit", "purchase required"),
    "credential_harvest": ("send password", "share your login", "bank login", "seed phrase", "private key"),
    "off_platform_only": ("telegram only", "whatsapp only", "contact me on telegram", "dm on whatsapp"),
    "unrealistic_payout": ("$5000 per day", "$10,000 per week", "guaranteed passive income"),
    "commission_only": ("commission only", "per successful hire", "per sale", "earn per successful"),
}

SENSITIVE_ACTION_TERMS = (
    "legal", "kyc", "tax", "purchase", "buy", "payment link", "send invoice",
    "upload passport", "government id", "bank account", "crypto wallet",
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def load_state(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return empty_state(path)
    try:
        data = json.loads(path.read_text())
    except Exception:
        backup = path.with_suffix(path.suffix + f".corrupt-{int(time.time())}")
        path.rename(backup)
        data = empty_state(path)
        append_event(data, "factory_state", "state_corrupt", f"Corrupt state moved to {backup}")
        data["qa_reviews"].append({
            "id": stable_id("qa", str(backup)),
            "milestone_id": "factory_state",
            "reviewer": "factory-runtime",
            "status": "needs_human",
            "checks_passed": 0,
            "checks_total": 1,
            "notes": f"Corrupt state moved to {backup}",
            "updated_at": utc_now(),
        })
    return normalize_state(data, path)


def save_state(path: pathlib.Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    normalized = normalize_state(state, path)
    normalized["generated_at"] = utc_now()
    with tempfile.NamedTemporaryFile("w", dir=str(path.parent), delete=False) as handle:
        json.dump(normalized, handle, indent=2, sort_keys=True)
        handle.write("\n")
        tmp_name = handle.name
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, path)


def empty_state(path: pathlib.Path) -> dict[str, Any]:
    return {
        "state_path": str(path),
        "generated_at": utc_now(),
        "currency": "USD",
        "max_workers": DEFAULT_MAX_WORKERS,
        "summary": base_summary(),
        "queues": [],
        "workers": [],
        "milestones": [],
        "qa_reviews": [],
        "payments": [],
        "opportunities": [],
        "revenue_ledger": [],
        "events": [],
        "approval_rules": [],
    }


def base_summary() -> dict[str, Any]:
    return {
        "active_workers": 0,
        "max_workers": DEFAULT_MAX_WORKERS,
        "queued_milestones": 0,
        "running_milestones": 0,
        "qa_blocked": 0,
        "ready_to_deliver": 0,
        "revenue_at_risk": 0,
        "currency": "USD",
        "found_opportunities": 0,
        "qualified_opportunities": 0,
        "drafted_opportunities": 0,
        "approved_to_submit": 0,
    }


def normalize_state(state: dict[str, Any], path: pathlib.Path) -> dict[str, Any]:
    state.setdefault("state_path", str(path))
    state["state_path"] = str(path)
    state.setdefault("generated_at", utc_now())
    state.setdefault("currency", "USD")
    state.setdefault("max_workers", DEFAULT_MAX_WORKERS)
    for key in ("milestones", "workers", "qa_reviews", "payments", "queues", "opportunities", "revenue_ledger", "events", "approval_rules"):
        if not isinstance(state.get(key), list):
            state[key] = []

    currency = str(state.get("currency") or "USD").upper()
    stages = ["demand", "proof", "paid", "executing", "qa", "delivery", "blocked"]
    stage_counts = {stage: 0 for stage in stages}
    revenue_at_risk = 0.0
    ready_to_deliver = 0
    qa_blocked = 0
    queued_milestones = 0
    running_milestones = 0

    for item in state["opportunities"]:
        normalize_opportunity(item, currency)
    state["opportunities"].sort(key=lambda item: float_or_zero((item.get("score") or {}).get("overall")), reverse=True)

    for item in state["milestones"]:
        item["stage"] = normalize_stage(item.get("stage"))
        item["qa_status"] = normalize_qa_status(item.get("qa_status"))
        item["payment_status"] = normalize_payment_status(item.get("payment_status"))
        item.setdefault("currency", currency)
        item.setdefault("proof_required", [])
        item.setdefault("artifact_urls", [])
        stage_counts[item["stage"]] = stage_counts.get(item["stage"], 0) + 1
        budget = float_or_zero(item.get("budget"))
        if item["stage"] != "delivery":
            revenue_at_risk += budget
        if item["stage"] in {"demand", "proof", "paid"}:
            queued_milestones += 1
        if item["stage"] == "executing":
            running_milestones += 1
        if item["stage"] == "delivery" and item["qa_status"] == "passed":
            ready_to_deliver += 1
        if item["stage"] == "blocked" or item["qa_status"] in {"failed", "needs_human"}:
            qa_blocked += 1

    for worker in state["workers"]:
        worker["role"] = normalize_worker_role(worker.get("role"))
        worker["status"] = normalize_worker_status(worker.get("status"))
        worker.setdefault("failure_count", 0)

    for entry in state["revenue_ledger"]:
        entry.setdefault("id", stable_id("ledger", entry.get("opportunity_id"), entry.get("milestone_id"), entry.get("quoted_amount")))
        entry.setdefault("status", "quoted")
        entry.setdefault("currency", currency)
        entry.setdefault("updated_at", utc_now())

    for rule in state["approval_rules"]:
        rule.setdefault("id", stable_id("rule", rule.get("platform"), rule.get("category"), rule.get("max_risk")))
        rule.setdefault("enabled", True)
        rule.setdefault("allowed_actions", ["mark approval-ready"])
        rule.setdefault("created_at", utc_now())

    active_workers = sum(1 for worker in state["workers"] if worker.get("status") == "running")
    max_workers = int(state.get("max_workers") or DEFAULT_MAX_WORKERS)
    statuses = [item.get("status") for item in state["opportunities"]]
    state["summary"] = {
        "active_workers": active_workers,
        "max_workers": max_workers,
        "queued_milestones": queued_milestones,
        "running_milestones": running_milestones,
        "qa_blocked": qa_blocked,
        "ready_to_deliver": ready_to_deliver,
        "revenue_at_risk": revenue_at_risk,
        "currency": currency,
        "found_opportunities": sum(1 for status in statuses if status in OPPORTUNITY_STATUSES),
        "qualified_opportunities": sum(1 for status in statuses if status in {"qualified", "ranked", "drafted", "approved_to_submit", "submitted", "accepted", "in_progress", "qa", "delivered", "invoiced", "paid"}),
        "drafted_opportunities": sum(1 for status in statuses if status in {"drafted", "approved_to_submit", "submitted", "accepted", "in_progress", "qa", "delivered", "invoiced", "paid"}),
        "approved_to_submit": sum(1 for status in statuses if status == "approved_to_submit"),
    }
    state["queues"] = [
        {
            "id": stage,
            "name": stage.replace("_", " ").title(),
            "stage": stage,
            "count": stage_counts.get(stage, 0),
            "oldest_age_minutes": None,
            "sla_minutes": 60 if stage in {"proof", "executing", "qa"} else None,
        }
        for stage in stages
    ]
    return state


def normalize_opportunity(item: dict[str, Any], currency: str) -> None:
    item.setdefault("id", stable_id("opp", item.get("source_url"), item.get("title"), item.get("raw_requirement")))
    item["status"] = normalize_opportunity_status(item.get("status"))
    item.setdefault("currency", currency)
    item.setdefault("platform", "unknown")
    item.setdefault("buyer", "Unknown buyer")
    item.setdefault("buyer_metadata", {})
    item.setdefault("raw_requirement", item.get("description") or item.get("title") or "")
    item.setdefault("normalized_deliverables", extract_deliverables(text_for_opportunity(item)))
    item.setdefault("acceptance_criteria", extract_acceptance(text_for_opportunity(item)))
    item.setdefault("required_tools", extract_tools(text_for_opportunity(item)))
    item.setdefault("risk_flags", risk_flags(text_for_opportunity(item)))
    item.setdefault("account_readiness", account_readiness(item))
    item.setdefault("events", [])
    item.setdefault("payment", {})
    item.setdefault("created_at", utc_now())
    item.setdefault("updated_at", utc_now())
    if not isinstance(item.get("score"), dict):
        item["score"] = {}
    if not isinstance(item.get("proposal_package"), dict):
        item["proposal_package"] = None


def normalize_opportunity_status(value: Any) -> str:
    value = str(value or "found").strip().lower().replace("-", "_").replace(" ", "_")
    aliases = {"shortlisted": "qualified", "approval_ready": "approved_to_submit", "working": "in_progress", "done": "delivered"}
    value = aliases.get(value, value)
    return value if value in OPPORTUNITY_STATUSES else "found"


def normalize_stage(value: Any) -> str:
    value = str(value or "demand").strip().lower().replace("-", "_").replace(" ", "_")
    aliases = {"lead": "demand", "leads": "demand", "scouting": "demand", "proofing": "proof", "proof_of_competence": "proof", "running": "executing", "work": "executing", "review": "qa", "ready": "delivery", "ready_to_deliver": "delivery"}
    value = aliases.get(value, value)
    return value if value in {"demand", "proof", "paid", "executing", "qa", "delivery", "blocked"} else "demand"


def normalize_qa_status(value: Any) -> str:
    value = str(value or "not_started").strip().lower().replace("-", "_").replace(" ", "_")
    value = {"ok": "passed", "pass": "passed", "fail": "failed", "human": "needs_human"}.get(value, value)
    return value if value in {"not_started", "pending", "passed", "failed", "needs_human"} else "not_started"


def normalize_payment_status(value: Any) -> str:
    value = str(value or "unpaid").strip().lower().replace("-", "_").replace(" ", "_")
    value = {"deposit": "deposit_paid", "partially_paid": "deposit_paid", "succeeded": "paid"}.get(value, value)
    return value if value in {"unpaid", "deposit_paid", "paid", "disputed", "refunded"} else "unpaid"


def normalize_worker_role(value: Any) -> str:
    value = str(value or "fulfillment").strip().lower().replace("-", "_").replace(" ", "_")
    value = {"worker": "fulfillment", "executor": "fulfillment", "reviewer": "qa", "billing": "payment"}.get(value, value)
    return value if value in {"scanner", "qualifier", "proof", "fulfillment", "qa", "delivery", "payment"} else "fulfillment"


def normalize_worker_status(value: Any) -> str:
    value = str(value or "idle").strip().lower().replace("-", "_").replace(" ", "_")
    value = {"active": "running", "working": "running", "paused": "waiting", "error": "failed"}.get(value, value)
    return value if value in {"idle", "queued", "running", "waiting", "blocked", "failed"} else "idle"


def stable_id(prefix: str, *parts: Any) -> str:
    return f"{prefix}_{uuid.uuid5(uuid.NAMESPACE_URL, ':'.join(str(part) for part in parts))}"


def float_or_zero(value: Any) -> float:
    try:
        return float(value)
    except Exception:
        return 0.0


def clamp(value: float, low: int = 0, high: int = 100) -> int:
    return max(low, min(high, int(round(value))))


def clean_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def text_for_opportunity(item: dict[str, Any]) -> str:
    parts = [
        item.get("title"),
        item.get("buyer"),
        item.get("platform"),
        item.get("raw_requirement"),
        item.get("budget"),
        item.get("source_url"),
    ]
    meta = item.get("buyer_metadata") if isinstance(item.get("buyer_metadata"), dict) else {}
    parts.extend(str(v) for v in meta.values() if isinstance(v, (str, int, float)))
    return clean_text("\n".join(str(part or "") for part in parts))


def contains_any(text: str, terms: tuple[str, ...] | list[str]) -> bool:
    lower = text.lower()
    return any(term in lower for term in terms)


def contains_sensitive_action(text: str) -> bool:
    lower = text.lower()
    for term in SENSITIVE_ACTION_TERMS:
        if re.search(rf"(?<![a-z0-9]){re.escape(term)}(?![a-z0-9])", lower):
            return True
    return False


def extract_budget(text: str) -> tuple[float, str]:
    matches = re.findall(r"(?:USD|CAD|\$)\s*([0-9][0-9,]*(?:\.\d+)?)", text, flags=re.I)
    values = [float(match.replace(",", "")) for match in matches]
    if values:
        return max(values), "USD"
    hourly = re.findall(r"([0-9]{2,4})\s*(?:/|per)\s*hour", text, flags=re.I)
    if hourly:
        return float(max(int(v) for v in hourly)) * 4, "USD"
    return 0.0, "USD"


def extract_tools(text: str) -> list[str]:
    lower = text.lower()
    aliases = {
        "n8n": ("n8n",),
        "Zapier": ("zapier",),
        "Make": ("make.com", "integromat"),
        "Stripe": ("stripe",),
        "WordPress": ("wordpress", "wp-admin"),
        "Shopify": ("shopify",),
        "Python": ("python",),
        "JavaScript": ("javascript", "node", "typescript"),
        "React": ("react", "next.js"),
        "Google Sheets": ("google sheets", "spreadsheet"),
        "Gmail": ("gmail", "email outreach"),
        "Airtable": ("airtable",),
        "Notion": ("notion",),
        "API": (" api", "rest", "graphql", "webhook"),
    }
    found = [name for name, keys in aliases.items() if any(key in lower for key in keys)]
    return found[:8] or ["Codex", "Browser", "Research"]


def extract_deliverables(text: str) -> list[str]:
    lower = text.lower()
    deliverables: list[str] = []
    if "workflow" in lower or "automation" in lower or "zapier" in lower or "n8n" in lower:
        deliverables.append("Working automation/workflow with run proof")
    if "stripe" in lower or "payment" in lower or "checkout" in lower:
        deliverables.append("Payment or webhook integration fix with replay evidence")
    if "website" in lower or "landing" in lower or "wordpress" in lower or "shopify" in lower:
        deliverables.append("Implemented site/app changes with screenshots and QA notes")
    if "scrape" in lower or "data" in lower or "research" in lower or "lead" in lower:
        deliverables.append("Clean dataset or research report with source links")
    if "bug" in lower or "fix" in lower or "error" in lower:
        deliverables.append("Reproduced fix with before/after evidence")
    return deliverables[:5] or ["Requirement-specific implementation package", "QA evidence", "Delivery note"]


def extract_acceptance(text: str) -> list[str]:
    lower = text.lower()
    criteria = ["Requirement is satisfied against the original post"]
    if "test" in lower or "qa" in lower or "bug" in lower:
        criteria.append("Before/after test or repro evidence is included")
    if "workflow" in lower or "automation" in lower:
        criteria.append("Workflow can be executed and produces the expected output")
    if "stripe" in lower or "webhook" in lower:
        criteria.append("Stripe/webhook event can be replayed without failure")
    if "website" in lower or "landing" in lower:
        criteria.append("Screenshots show the final user-facing state")
    return criteria[:5]


def risk_flags(text: str) -> list[str]:
    lower = text.lower()
    flags: list[str] = []
    for name, phrases in HARD_REJECT_FLAGS.items():
        if any(phrase in lower for phrase in phrases):
            flags.append(name)
    if len(text) < 140:
        flags.append("low_context")
    if not contains_any(lower, EXECUTABLE_TERMS):
        flags.append("unclear_samantha_fit")
    if re.search(r"\b(full[- ]time|employee|benefits|salary|annual|years of experience|\d\+ years|bachelor'?s degree|senior accountant|account supervisor)\b", lower):
        flags.append("employment_role")
    if re.search(r"\b\[?for hire\]?\b|\bi'?m a\b|\bi am a\b|\bmy services\b", lower):
        flags.append("seller_post")
    if extract_budget(text)[0] > 5000 and "milestone" not in lower and "fixed" not in lower and "project" not in lower:
        flags.append("salary_or_not_milestone_work")
    if "senior" in lower and "architect" in lower:
        flags.append("high_expectation")
    return sorted(set(flags))


def account_readiness(item: dict[str, Any]) -> str:
    platform = str(item.get("platform") or "").lower()
    if platform in {"remoteok", "github", "rss", "web"}:
        return "source-only; draft package can be prepared"
    if platform in {"upwork", "fiverr", "bugcrowd", "hackerone"}:
        return "requires authenticated account and user approval"
    return "unknown"


def append_event(state: dict[str, Any], subject_id: str, action: str, evidence: str, *, external_url: str | None = None) -> None:
    state.setdefault("events", [])
    now = utc_now()
    state["events"].append({
        "id": stable_id("evt", subject_id, action, evidence, time.time()),
        "subject_id": subject_id,
        "action": action,
        "evidence": evidence,
        "external_url": external_url,
        "timestamp": now,
        "created_at": now,
    })


def upsert_opportunity(state: dict[str, Any], opportunity: dict[str, Any]) -> bool:
    currency = str(state.get("currency") or "USD").upper()
    normalize_opportunity(opportunity, currency)
    for existing in state["opportunities"]:
        if existing.get("id") == opportunity.get("id") or (existing.get("source_url") and existing.get("source_url") == opportunity.get("source_url")):
            existing.update({**opportunity, "updated_at": utc_now()})
            normalize_opportunity(existing, currency)
            return False
    state["opportunities"].append(opportunity)
    return True


def remoteok_jobs(limit: int) -> list[dict[str, Any]]:
    req = urllib.request.Request(REMOTEOK_API, headers={"User-Agent": "ipop-samantha-factory/1.0"})
    with urllib.request.urlopen(req, timeout=20) as response:
        data = json.loads(response.read().decode("utf-8", "replace"))
    jobs = [item for item in data if isinstance(item, dict) and item.get("id")]
    return jobs[:limit]


def rss_jobs(urls: list[str], limit: int) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    for url in urls:
        req = urllib.request.Request(url, headers={"User-Agent": "ipop-samantha-factory/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                root = ET.fromstring(response.read())
        except Exception:
            continue
        for entry in root.findall(".//{*}item") + root.findall(".//{*}entry"):
            title = clean_text((entry.findtext("{*}title") or entry.findtext("title") or "RSS paid-work post"))
            link = clean_text((entry.findtext("{*}link") or entry.findtext("link") or ""))
            if not link:
                link_node = entry.find("{*}link")
                if link_node is not None:
                    link = clean_text(link_node.attrib.get("href", ""))
            description = clean_text(
                entry.findtext("{*}description")
                or entry.findtext("{*}summary")
                or entry.findtext("{*}content")
                or title
            )
            jobs.append({
                "id": stable_id("rss", url, link, title),
                "position": title,
                "company": clean_text(url.split("/")[2] if "/" in url else "RSS source"),
                "description": re.sub(r"<[^>]+>", " ", description),
                "url": link or url,
                "tags": ["rss", "paid-work"],
            })
            if len(jobs) >= limit:
                return jobs
    return jobs


def sample_jobs() -> list[dict[str, Any]]:
    return [
        {
            "id": "sample-stripe-webhook",
            "position": "Fix Stripe checkout webhook and customer email automation",
            "company": "Remote SaaS founder",
            "description": "Need a developer to debug Stripe checkout.session.completed failures, add a reliable webhook replay test, and document deployment. Budget $450. Remote, fast turnaround.",
            "url": "https://remoteok.com/remote-jobs/sample-stripe-webhook",
            "tags": ["stripe", "webhook", "automation"],
        },
        {
            "id": "sample-n8n-leads",
            "position": "Build n8n workflow to enrich leads and send Gmail drafts",
            "company": "B2B agency",
            "description": "Looking for an automation specialist to create a requirement-specific n8n workflow using Google Sheets, enrichment API, and Gmail draft creation. Budget $600. Must include test run proof.",
            "url": "https://remoteok.com/remote-jobs/sample-n8n-leads",
            "tags": ["n8n", "gmail", "sheets", "api"],
        },
        {
            "id": "sample-wordpress-speed",
            "position": "WordPress bug fix and speed cleanup",
            "company": "Local services company",
            "description": "Our WordPress contact form is broken and pages are slow. Need form fixed, screenshots, and Lighthouse before/after proof. Budget $300.",
            "url": "https://remoteok.com/remote-jobs/sample-wordpress-speed",
            "tags": ["wordpress", "qa"],
        },
        {
            "id": "sample-risky",
            "position": "Easy remote work, buy starter kit first",
            "company": "Unknown",
            "description": "Guaranteed $5000 per day. Purchase required. Contact me on Telegram only.",
            "url": "https://remoteok.com/remote-jobs/sample-risky",
            "tags": ["admin"],
        },
    ]


def opportunity_from_remoteok(job: dict[str, Any]) -> dict[str, Any]:
    title = clean_text(job.get("position") or job.get("title") or "Remote work requirement")
    company = clean_text(job.get("company") or "Remote buyer")
    description = clean_text(job.get("description") or job.get("tags") or title)
    tags = job.get("tags") if isinstance(job.get("tags"), list) else []
    raw = clean_text(f"{title}. {description}. Tags: {', '.join(str(tag) for tag in tags)}")
    budget, currency = extract_budget(raw)
    source_url = str(job.get("url") or f"https://remoteok.com/remote-jobs/{job.get('id')}")
    return {
        "id": stable_id("opp", "remoteok", job.get("id"), source_url),
        "source": "remoteok",
        "raw_requirement": raw,
        "title": title,
        "normalized_deliverables": extract_deliverables(raw),
        "acceptance_criteria": extract_acceptance(raw),
        "budget": budget,
        "currency": currency,
        "urgency": "recent remote post",
        "platform": "RemoteOK",
        "buyer": company,
        "buyer_metadata": {"tags": ", ".join(str(tag) for tag in tags), "job_id": str(job.get("id") or "")},
        "source_url": source_url,
        "contact_route": source_url,
        "required_tools": extract_tools(raw),
        "account_readiness": "source-only; draft package can be prepared",
        "risk_flags": risk_flags(raw),
        "score": {},
        "proposal_package": None,
        "execution_plan": [],
        "status": "found",
        "events": [],
        "payment": None,
        "created_at": utc_now(),
        "updated_at": utc_now(),
    }


def quality_gate(item: dict[str, Any]) -> tuple[bool, list[str]]:
    text = text_for_opportunity(item)
    reasons: list[str] = []
    flags = risk_flags(text)
    if not str(item.get("source_url") or "").strip():
        flags.append("missing_source_url")
    has_project_payment_signal = re.search(r"\b(budget|fixed|milestone|project|contract|freelance|hourly|\$)\b", text, flags=re.I)
    if not has_project_payment_signal:
        flags.append("payment_unclear")
    if "low_context" in flags:
        reasons.append("posting is too thin to safely quote or execute")
    hard = [flag for flag in flags if flag in HARD_REJECT_FLAGS or flag in {"missing_source_url", "payment_unclear", "employment_role", "salary_or_not_milestone_work", "seller_post"}]
    if hard:
        reasons.extend(hard)
    if not contains_any(text, EXECUTABLE_TERMS):
        reasons.append("no clear Samantha-executable deliverable")
    if not contains_any(text, CLEAR_WORK_TERMS):
        hard.append("no_milestone_action")
        reasons.append("posting reads like a role, not a milestone deliverable")
    accepted = not hard and "unclear_samantha_fit" not in flags
    return accepted, sorted(set(reasons or ["paid, clear enough, and executable by Samantha"]))


def score_opportunity(item: dict[str, Any]) -> dict[str, Any]:
    text = text_for_opportunity(item)
    lower = text.lower()
    budget = float_or_zero(item.get("budget"))
    flags = item.get("risk_flags") or risk_flags(text)
    clarity = 78 if len(text) > 260 else 55
    if any(word in lower for word in ("acceptance", "deliver", "test", "proof", "workflow", "fix", "bug")):
        clarity += 12
    payout = 35 if budget <= 0 else min(100, 45 + budget / 12)
    time_to_cash = 82 if any(word in lower for word in ("urgent", "asap", "today", "quick", "fast", "fix")) else 62
    fit = 45 + min(45, len(set(extract_tools(text))) * 8)
    if contains_any(lower, ("n8n", "stripe", "wordpress", "automation", "api", "python", "gmail", "sheets")):
        fit += 12
    trust = 65 if item.get("source_url") else 30
    if item.get("buyer") and str(item.get("buyer")).lower() not in {"unknown", "unknown buyer"}:
        trust += 12
    competition = 55
    if "remoteok" in str(item.get("platform", "")).lower():
        competition -= 7
    risk = max(0, 100 - (len(flags) * 18))
    readiness = 72 if "source-only" in str(item.get("account_readiness", "")).lower() else 48
    overall = (
        clamp(trust) * 0.13
        + clamp(time_to_cash) * 0.15
        + clamp(payout) * 0.13
        + clamp(clarity) * 0.14
        + clamp(fit) * 0.22
        + clamp(risk) * 0.16
        + clamp(readiness) * 0.07
    )
    reasons = [
        f"fit={clamp(fit)} from tools {', '.join(extract_tools(text)[:4])}",
        f"clarity={clamp(clarity)} from requirement detail",
        f"payout={clamp(payout)} quoted/budget signal {budget:g}",
        f"risk={clamp(risk)} flags {', '.join(flags) if flags else 'none'}",
        f"time_to_cash={clamp(time_to_cash)}",
    ]
    return {
        "overall": clamp(overall),
        "payment_probability": clamp(trust),
        "payment_confidence": clamp(trust),
        "time_to_cash": clamp(time_to_cash),
        "payout": clamp(payout),
        "payout_size": clamp(payout),
        "effort": clamp(100 - max(20, len(text) / 20)),
        "effort_estimate": clamp(100 - max(20, len(text) / 20)),
        "buyer_trust": clamp(trust),
        "requirement_clarity": clamp(clarity),
        "competition": clamp(competition),
        "capability_fit": clamp(fit),
        "samantha_fit": clamp(fit),
        "account_readiness": clamp(readiness),
        "approval_readiness": clamp(readiness),
        "risk": clamp(100 - risk),
        "execution_risk": clamp(100 - risk),
        "reasons": reasons,
    }


def proposal_package(item: dict[str, Any]) -> dict[str, Any]:
    title = clean_text(item.get("title") or "Remote work requirement")
    deliverables = item.get("normalized_deliverables") or extract_deliverables(text_for_opportunity(item))
    acceptance = item.get("acceptance_criteria") or extract_acceptance(text_for_opportunity(item))
    tools = item.get("required_tools") or extract_tools(text_for_opportunity(item))
    budget = float_or_zero(item.get("budget"))
    quoted = budget if budget > 0 else 350.0
    milestone = max(99.0, round(quoted * 0.5, 2))
    problem = f"{item.get('buyer', 'The buyer')} needs {title.lower()} with proof that the requirement is actually working."
    plan = [
        "Confirm the original requirement and access needed.",
        "Reproduce or model the current failure/desired workflow.",
        "Implement the smallest complete fix or workflow.",
        "Run QA against the acceptance criteria and package proof.",
        "Deliver artifacts plus a short change log.",
    ]
    proposal = (
        f"I can take this as a proof-first milestone. I will deliver {', '.join(deliverables[:2]).lower()} "
        f"and include QA evidence against: {'; '.join(acceptance[:3])}. "
        f"Suggested first milestone: {milestone:g} {item.get('currency', 'USD')} after proof is accepted."
    )
    return {
        "buyer_problem_summary": problem,
        "exact_deliverables": deliverables,
        "acceptance_criteria": acceptance,
        "work_plan": plan,
        "milestone_split": [
            f"Milestone 1 proof package: {milestone:g} {item.get('currency', 'USD')}",
            f"Final delivery / handoff: {max(0, quoted - milestone):g} {item.get('currency', 'USD')}",
        ],
        "access_needed": [f"Access or sample data for {tool}" for tool in tools[:4]],
        "proof_plan": acceptance + ["Attach screenshots/logs/source links before external delivery"],
        "proof_qa_plan": acceptance + ["Attach screenshots/logs/source links before external delivery"],
        "pricing_recommendation": f"Quote {quoted:g} {item.get('currency', 'USD')} with proof-first milestone; invoice only after acceptance.",
        "pricing_payment_recommendation": f"Quote {quoted:g} {item.get('currency', 'USD')} with proof-first milestone; invoice only after acceptance.",
        "proposal_text": proposal,
    }


def ledger_entry_for(item: dict[str, Any]) -> dict[str, Any]:
    quoted = float_or_zero(item.get("budget")) or 350.0
    return {
        "id": stable_id("ledger", item.get("id"), quoted),
        "opportunity_id": item.get("id"),
        "milestone_id": None,
        "projected_value": quoted,
        "quoted_value": quoted,
        "accepted_value": 0,
        "invoiced_value": 0,
        "pending_payment": 0,
        "platform_fees": 0,
        "net_received": 0,
        "quoted_amount": quoted,
        "invoiced_amount": 0,
        "paid_amount": 0,
        "currency": item.get("currency") or "USD",
        "payment_status": "unpaid",
        "status": "quoted",
        "payment_provider": "Stripe/manual invoice",
        "blocker_reason": "Awaiting buyer acceptance and approved submission",
        "blocker": "Awaiting buyer acceptance and approved submission",
        "updated_at": utc_now(),
    }


def discover(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    jobs: list[dict[str, Any]]
    source = args.source.lower()
    try:
        if source == "sample":
            jobs = sample_jobs()
        elif source == "rss":
            jobs = rss_jobs(args.url or list(DEFAULT_RSS_SOURCES), args.limit * 3)
        else:
            jobs = remoteok_jobs(args.limit * 3)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        jobs = sample_jobs()
        append_event(state, "discovery", "source_fallback", f"{source} failed, used sample jobs: {exc}")

    added = 0
    for job in jobs:
        opportunity = opportunity_from_remoteok(job)
        text = text_for_opportunity(opportunity)
        if source != "sample" and not contains_any(text, EXECUTABLE_TERMS):
            continue
        if upsert_opportunity(state, opportunity):
            added += 1
            append_event(state, opportunity["id"], "discovered", f"Discovered from {opportunity['platform']}: {opportunity['title']}", external_url=opportunity.get("source_url"))
        if len(state["opportunities"]) >= args.limit:
            break
    save_state(state_path, state)
    print(json.dumps({"discovered": added, "total_opportunities": len(load_state(state_path)["opportunities"]), "state": str(state_path)}))


def qualify(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    changed = 0
    for item in state["opportunities"]:
        if item.get("status") not in {"found", "parsed"}:
            continue
        accepted, reasons = quality_gate(item)
        item["risk_flags"] = risk_flags(text_for_opportunity(item))
        item["status"] = "qualified" if accepted else "rejected"
        item["qualification_reasons"] = reasons
        item["updated_at"] = utc_now()
        append_event(state, item["id"], "qualified" if accepted else "rejected", "; ".join(reasons), external_url=item.get("source_url"))
        changed += 1
    save_state(state_path, state)
    print(json.dumps({"qualified_or_rejected": changed, "state": str(state_path)}))


def rank(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    ranked = 0
    for item in state["opportunities"]:
        if item.get("status") not in {"qualified", "ranked", "drafted", "approved_to_submit"}:
            continue
        item["score"] = score_opportunity(item)
        if item["status"] == "qualified":
            item["status"] = "ranked"
        item["updated_at"] = utc_now()
        append_event(state, item["id"], "ranked", "; ".join((item["score"].get("reasons") or [])[:3]), external_url=item.get("source_url"))
        ranked += 1
    save_state(state_path, state)
    print(json.dumps({"ranked": ranked, "state": str(state_path)}))


def draft(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    drafted = 0
    candidates = [item for item in state["opportunities"] if item.get("status") in {"qualified", "ranked"}]
    candidates.sort(key=lambda item: float_or_zero((item.get("score") or {}).get("overall")), reverse=True)
    existing_ledger_ids = {entry.get("opportunity_id") for entry in state["revenue_ledger"]}
    for item in candidates[: args.limit]:
        if not item.get("score"):
            item["score"] = score_opportunity(item)
        item["proposal_package"] = proposal_package(item)
        item["execution_plan"] = item["proposal_package"]["work_plan"]
        item["status"] = "drafted"
        item["updated_at"] = utc_now()
        if item.get("id") not in existing_ledger_ids:
            state["revenue_ledger"].append(ledger_entry_for(item))
            existing_ledger_ids.add(item.get("id"))
        append_event(state, item["id"], "proposal_package_drafted", item["proposal_package"]["proposal_text"], external_url=item.get("source_url"))
        drafted += 1
    save_state(state_path, state)
    print(json.dumps({"drafted": drafted, "state": str(state_path)}))


def approve_rule(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    rule = {
        "id": args.id or stable_id("rule", args.platform, args.category, args.max_risk, args.max_quoted_amount),
        "source": args.platform,
        "platform": args.platform,
        "category": args.category,
        "max_risk": args.max_risk,
        "max_quoted_value": args.max_quoted_amount,
        "max_quoted_amount": args.max_quoted_amount,
        "allowed_actions": args.allowed_action,
        "enabled": not args.disabled,
        "created_at": utc_now(),
    }
    state["approval_rules"] = [existing for existing in state["approval_rules"] if existing.get("id") != rule["id"]]
    state["approval_rules"].append(rule)
    append_event(state, rule["id"], "approval_rule_saved", f"{rule['platform']} {rule['category']} max_risk={rule['max_risk']}")
    save_state(state_path, state)
    print(json.dumps({"approval_rule": rule["id"], "state": str(state_path)}))


def rule_matches(rule: dict[str, Any], item: dict[str, Any]) -> bool:
    if not rule.get("enabled", True):
        return False
    platform = str(rule.get("platform") or "*").lower()
    if platform not in {"*", "any"} and platform not in str(item.get("platform") or "").lower():
        return False
    quoted = float_or_zero(item.get("budget")) or 350.0
    if quoted > float_or_zero(rule.get("max_quoted_amount")) > 0:
        return False
    score = item.get("score") or score_opportunity(item)
    if float_or_zero(score.get("execution_risk")) > float_or_zero(rule.get("max_risk")):
        return False
    package_text = json.dumps(item.get("proposal_package") or {}, sort_keys=True).lower()
    if contains_sensitive_action(package_text):
        return False
    return True


def submit_ready(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    ready = 0
    for item in state["opportunities"]:
        if item.get("status") != "drafted":
            continue
        matching = [rule for rule in state["approval_rules"] if rule_matches(rule, item)]
        if not matching:
            append_event(state, item["id"], "approval_blocked", "No stored approval rule matched this drafted opportunity", external_url=item.get("source_url"))
            continue
        item["status"] = "approved_to_submit"
        item["approval_rule_id"] = matching[0]["id"]
        item["updated_at"] = utc_now()
        append_event(state, item["id"], "approved_to_submit", f"Matched approval rule {matching[0]['id']}; no external submit performed", external_url=item.get("source_url"))
        ready += 1
    save_state(state_path, state)
    print(json.dumps({"approved_to_submit": ready, "state": str(state_path)}))


def promote_to_milestone(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    allowed_status = {"accepted"} | ({"approved_to_submit"} if args.allow_approved else set())
    promoted = 0
    for item in state["opportunities"]:
        if item.get("status") not in allowed_status:
            continue
        package = item.get("proposal_package") or proposal_package(item)
        milestone_id = stable_id("ms", item.get("id"), item.get("title"))
        if any(ms.get("id") == milestone_id for ms in state["milestones"]):
            continue
        milestone = {
            "id": milestone_id,
            "source": f"opportunity:{item.get('platform')}",
            "client_signal": item.get("raw_requirement"),
            "offer": item.get("title") or "Requirement-driven remote job",
            "budget": float_or_zero(item.get("budget")) or 350.0,
            "currency": item.get("currency") or state.get("currency") or "USD",
            "stage": "proof",
            "assigned_worker_id": None,
            "qa_status": "not_started",
            "payment_status": "unpaid",
            "proof_required": package.get("acceptance_criteria") or item.get("acceptance_criteria") or [],
            "artifact_urls": [item.get("source_url")] if item.get("source_url") else [],
            "allowed_actions": ["read", "diagnose", "draft", "local proof", "implement local artifact"],
            "blocked_actions": ["submit proposal", "send message", "charge card", "publish", "delete external data"],
            "opportunity_id": item.get("id"),
            "updated_at": utc_now(),
        }
        state["milestones"].append(milestone)
        item["status"] = "in_progress"
        item["milestone_id"] = milestone_id
        item["updated_at"] = utc_now()
        for ledger in state["revenue_ledger"]:
            if ledger.get("opportunity_id") == item.get("id"):
                ledger["milestone_id"] = milestone_id
                ledger["status"] = "accepted" if not args.allow_approved else "approval_ready"
                ledger["blocker"] = "Promoted to execution milestone; buyer acceptance still required" if args.allow_approved else "Accepted; execution in progress"
                ledger["blocker_reason"] = ledger["blocker"]
                ledger["updated_at"] = utc_now()
        append_event(state, item["id"], "promoted_to_milestone", f"Promoted to {milestone_id}", external_url=item.get("source_url"))
        promoted += 1
        if promoted >= args.limit:
            break
    save_state(state_path, state)
    print(json.dumps({"promoted": promoted, "state": str(state_path)}))


def enqueue(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    payload = json.loads(args.json) if args.json else {}
    milestone = {
        "id": payload.get("id") or stable_id("ms", payload.get("source", args.source), payload.get("client_signal", args.client_signal), time.time()),
        "source": payload.get("source") or args.source,
        "client_signal": payload.get("client_signal") or args.client_signal,
        "offer": payload.get("offer") or args.offer,
        "budget": float_or_zero(payload.get("budget", args.budget)),
        "currency": str(payload.get("currency") or args.currency).upper(),
        "stage": normalize_stage(payload.get("stage") or args.stage),
        "assigned_worker_id": payload.get("assigned_worker_id"),
        "qa_status": normalize_qa_status(payload.get("qa_status")),
        "payment_status": normalize_payment_status(payload.get("payment_status")),
        "proof_required": payload.get("proof_required") or ["artifact", "qa summary", "delivery note"],
        "artifact_urls": payload.get("artifact_urls") or [],
        "allowed_actions": payload.get("allowed_actions") or ["read", "diagnose", "draft", "local proof"],
        "blocked_actions": payload.get("blocked_actions") or ["submit proposal", "send message", "charge card", "publish", "delete external data"],
        "updated_at": utc_now(),
    }
    state["milestones"].append(milestone)
    append_event(state, milestone["id"], "milestone_enqueued", milestone["offer"])
    save_state(state_path, state)
    print(json.dumps({"enqueued": milestone["id"], "state": str(state_path)}))


def run_once(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    artifact_dir = pathlib.Path(args.artifact_dir)
    state = load_state(state_path)
    max_workers = min(args.max_workers, int(state.get("max_workers") or args.max_workers))
    claimable = [item for item in state["milestones"] if normalize_stage(item.get("stage")) in {"demand", "proof", "paid"} and normalize_qa_status(item.get("qa_status")) != "failed"][: args.limit]
    if not claimable:
        save_state(state_path, state)
        print(json.dumps({"claimed": 0, "state": str(state_path)}))
        return

    for item in claimable:
        item["stage"] = "executing"
        item["qa_status"] = "pending"
        item["updated_at"] = utc_now()
        worker_id = stable_id("worker", item["id"], item.get("offer"), time.time())
        item["assigned_worker_id"] = worker_id
        state["workers"].append({"id": worker_id, "name": f"{normalize_worker_role(args.role)}-{item['id'][:8]}", "role": normalize_worker_role(args.role), "status": "running", "current_milestone_id": item["id"], "started_at": utc_now(), "workspace_url": None, "proof_url": None, "failure_count": 0})
        append_event(state, item["id"], "worker_claimed", f"{worker_id} claimed milestone")
    save_state(state_path, state)

    by_id = {item["id"]: item for item in claimable}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(execute_milestone, item, artifact_dir, args.timeout, args.codex): item["id"] for item in claimable}
        for future in concurrent.futures.as_completed(futures):
            milestone_id = futures[future]
            result = future.result()
            state = load_state(state_path)
            apply_worker_result(state, by_id[milestone_id], result)
            save_state(state_path, state)
    print(json.dumps({"claimed": len(claimable), "state": str(state_path)}))


def execute_milestone(item: dict[str, Any], artifact_dir: pathlib.Path, timeout: int, codex_command: str) -> dict[str, Any]:
    milestone_dir = artifact_dir / item["id"]
    milestone_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = milestone_dir / "prompt.md"
    stdout_path = milestone_dir / "worker.out"
    stderr_path = milestone_dir / "worker.err"
    summary_path = milestone_dir / "summary.json"
    prompt_path.write_text(worker_prompt(item, milestone_dir))
    command = f"{codex_command} exec --skip-git-repo-check < {shlex.quote(str(prompt_path))}"
    started = utc_now()
    try:
        completed = subprocess.run(["/bin/sh", "-lc", command], capture_output=True, text=True, timeout=timeout + 15)
        stdout_path.write_text(completed.stdout or "")
        stderr_path.write_text(completed.stderr or "")
        ok = completed.returncode == 0
        notes = (completed.stdout or completed.stderr or "").strip().splitlines()[:8]
        result = {"ok": ok, "returncode": completed.returncode, "started_at": started, "finished_at": utc_now(), "artifact_urls": [str(prompt_path), str(stdout_path), str(stderr_path)], "notes": "\n".join(notes)}
    except Exception as exc:
        result = {"ok": False, "returncode": 124, "started_at": started, "finished_at": utc_now(), "artifact_urls": [str(prompt_path)], "notes": str(exc)}
    summary_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    result["artifact_urls"].append(str(summary_path))
    return result


def worker_prompt(item: dict[str, Any], milestone_dir: pathlib.Path) -> str:
    return f"""You are an iPOP/Samantha worker agent executing one milestone inside a parallel factory.

Milestone JSON:
~~~json
{json.dumps(item, indent=2, sort_keys=True)}
~~~

Rules:
- Produce proof for this milestone in {milestone_dir}.
- Do not send messages, submit proposals, publish externally, charge cards, buy anything, or mutate client accounts unless the milestone's allowed_actions explicitly includes that exact action.
- Prefer local artifacts: diagnosis markdown, patch, workflow JSON, screenshots/log instructions, QA checklist.
- End with a concise delivery note and a QA checklist.
"""


def apply_worker_result(state: dict[str, Any], original: dict[str, Any], result: dict[str, Any]) -> None:
    milestone_id = original["id"]
    worker_id = original.get("assigned_worker_id")
    for item in state["milestones"]:
        if item.get("id") == milestone_id:
            item["stage"] = "qa" if result["ok"] else "blocked"
            item["qa_status"] = "passed" if result["ok"] else "failed"
            item["artifact_urls"] = sorted(set((item.get("artifact_urls") or []) + result["artifact_urls"]))
            item["updated_at"] = utc_now()
            if item.get("opportunity_id"):
                update_opportunity_after_worker(state, item, result)
            break
    for worker in state["workers"]:
        if worker.get("id") == worker_id:
            worker["status"] = "idle" if result["ok"] else "failed"
            worker["proof_url"] = result["artifact_urls"][-1] if result["artifact_urls"] else None
            worker["failure_count"] = int(worker.get("failure_count") or 0) + (0 if result["ok"] else 1)
            break
    state["qa_reviews"].append({"id": stable_id("qa", milestone_id, result.get("finished_at")), "milestone_id": milestone_id, "reviewer": "factory-runtime", "status": "passed" if result["ok"] else "failed", "checks_passed": 3 if result["ok"] else 1, "checks_total": 3, "notes": result.get("notes") or "", "updated_at": utc_now()})
    append_event(state, milestone_id, "worker_result", "passed" if result["ok"] else "failed")


def update_opportunity_after_worker(state: dict[str, Any], milestone: dict[str, Any], result: dict[str, Any]) -> None:
    for opp in state["opportunities"]:
        if opp.get("id") == milestone.get("opportunity_id"):
            opp["status"] = "qa" if result["ok"] else "in_progress"
            opp["updated_at"] = utc_now()
            append_event(state, opp["id"], "worker_artifact_ready" if result["ok"] else "worker_artifact_failed", result.get("notes") or "", external_url=milestone.get("artifact_urls", [None])[-1])
            break


def loop(args: argparse.Namespace) -> None:
    while True:
        run_once(args)
        time.sleep(args.interval)


def init(args: argparse.Namespace) -> None:
    state_path = pathlib.Path(args.state)
    state = load_state(state_path)
    state["max_workers"] = args.max_workers
    save_state(state_path, state)
    print(json.dumps({"initialized": str(state_path), "max_workers": args.max_workers}))


def selftest(args: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        state_path = pathlib.Path(tmp) / "ipop-factory.json"
        artifact_dir = pathlib.Path(tmp) / "artifacts"
        init(argparse.Namespace(state=str(state_path), max_workers=2))
        discover(argparse.Namespace(state=str(state_path), source="sample", limit=25))
        qualify(argparse.Namespace(state=str(state_path)))
        rank(argparse.Namespace(state=str(state_path)))
        draft(argparse.Namespace(state=str(state_path), limit=5))
        approve_rule(argparse.Namespace(state=str(state_path), id="", platform="RemoteOK", category="automation", max_risk=45, max_quoted_amount=1000, allowed_action=["mark approval-ready"], disabled=False))
        submit_ready(argparse.Namespace(state=str(state_path)))
        promote_to_milestone(argparse.Namespace(state=str(state_path), limit=1, allow_approved=True))
        enqueue(argparse.Namespace(state=str(state_path), json="", source="selftest", client_signal="Need a proof artifact", offer="Factory Selftest", budget=10, currency="USD", stage="proof"))
        run_once(argparse.Namespace(state=str(state_path), artifact_dir=str(artifact_dir), max_workers=1, limit=1, timeout=5, codex="printf SELFTEST_OK #", role="proof"))
        data = load_state(state_path)
        assert data["summary"]["qualified_opportunities"] >= 1, data
        assert data["summary"]["drafted_opportunities"] >= 1, data
        assert data["summary"]["qa_blocked"] == 0, data
        assert data["qa_reviews"], data
        assert data["revenue_ledger"], data
        assert any(event.get("action") == "approved_to_submit" for event in data["events"]), data
    print("SELFTEST_OK")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the iPOP/Samantha paid remote-work factory.")
    parser.add_argument("--state", default=str(DEFAULT_STATE_PATH))
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("--max-workers", type=int, default=DEFAULT_MAX_WORKERS)
    p_init.set_defaults(func=init)

    p_discover = sub.add_parser("discover")
    p_discover.add_argument("--source", default="remoteok", choices=["remoteok", "rss", "sample"])
    p_discover.add_argument("--url", action="append", default=[])
    p_discover.add_argument("--limit", type=int, default=25)
    p_discover.set_defaults(func=discover)

    p_qualify = sub.add_parser("qualify")
    p_qualify.set_defaults(func=qualify)

    p_rank = sub.add_parser("rank")
    p_rank.set_defaults(func=rank)

    p_draft = sub.add_parser("draft")
    p_draft.add_argument("--limit", type=int, default=5)
    p_draft.set_defaults(func=draft)

    p_rule = sub.add_parser("approve-rule")
    p_rule.add_argument("--id", default="")
    p_rule.add_argument("--platform", default="*")
    p_rule.add_argument("--category", default="automation")
    p_rule.add_argument("--max-risk", type=int, default=35)
    p_rule.add_argument("--max-quoted-amount", type=float, default=1000.0)
    p_rule.add_argument("--allowed-action", action="append", default=[])
    p_rule.add_argument("--disabled", action="store_true")
    p_rule.set_defaults(func=approve_rule)

    p_ready = sub.add_parser("submit-ready")
    p_ready.set_defaults(func=submit_ready)

    p_promote = sub.add_parser("promote-to-milestone")
    p_promote.add_argument("--limit", type=int, default=1)
    p_promote.add_argument("--allow-approved", action="store_true")
    p_promote.set_defaults(func=promote_to_milestone)

    p_enqueue = sub.add_parser("enqueue")
    p_enqueue.add_argument("--json", default="")
    p_enqueue.add_argument("--source", default="manual")
    p_enqueue.add_argument("--client-signal", default="Unspecified client demand")
    p_enqueue.add_argument("--offer", default="Agent milestone")
    p_enqueue.add_argument("--budget", type=float, default=0.0)
    p_enqueue.add_argument("--currency", default="USD")
    p_enqueue.add_argument("--stage", default="proof")
    p_enqueue.set_defaults(func=enqueue)

    for name, func in (("run-once", run_once), ("loop", loop)):
        p_run = sub.add_parser(name)
        p_run.add_argument("--artifact-dir", default=str(DEFAULT_ARTIFACT_DIR))
        p_run.add_argument("--max-workers", type=int, default=DEFAULT_MAX_WORKERS)
        p_run.add_argument("--limit", type=int, default=DEFAULT_MAX_WORKERS)
        p_run.add_argument("--timeout", type=int, default=900)
        p_run.add_argument("--codex", default=os.environ.get("IPOP_FACTORY_CODEX", "codex"))
        p_run.add_argument("--role", default="fulfillment")
        if name == "loop":
            p_run.add_argument("--interval", type=int, default=30)
        p_run.set_defaults(func=func)

    p_selftest = sub.add_parser("selftest")
    p_selftest.set_defaults(func=selftest)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
