#!/usr/bin/env python3
"""File-backed iPOP/Samantha parallel work factory.

This is intentionally small and dependency-free so a fresh Samantha VM can run
it before Postgres/Redis/Temporal exist. It owns the JSON contract consumed by
the OS1 Factory view and gives Samantha a real bounded worker pool for parallel
milestone execution.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import shlex
import subprocess
import tempfile
import time
import uuid
from typing import Any


DEFAULT_STATE_PATH = pathlib.Path(os.environ.get("IPOP_FACTORY_STATE", "/root/ipop-factory.json"))
DEFAULT_ARTIFACT_DIR = pathlib.Path(os.environ.get("IPOP_FACTORY_ARTIFACT_DIR", "/root/ipop-factory-artifacts"))
DEFAULT_MAX_WORKERS = int(os.environ.get("IPOP_FACTORY_MAX_WORKERS", "4"))


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
        "summary": {
            "active_workers": 0,
            "max_workers": DEFAULT_MAX_WORKERS,
            "queued_milestones": 0,
            "running_milestones": 0,
            "qa_blocked": 0,
            "ready_to_deliver": 0,
            "revenue_at_risk": 0,
            "currency": "USD",
        },
        "queues": [],
        "workers": [],
        "milestones": [],
        "qa_reviews": [],
        "payments": [],
    }


def normalize_state(state: dict[str, Any], path: pathlib.Path) -> dict[str, Any]:
    state.setdefault("state_path", str(path))
    state["state_path"] = str(path)
    state.setdefault("generated_at", utc_now())
    state.setdefault("currency", "USD")
    state.setdefault("max_workers", DEFAULT_MAX_WORKERS)
    for key in ("milestones", "workers", "qa_reviews", "payments", "queues"):
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

    active_workers = sum(1 for worker in state["workers"] if worker.get("status") == "running")
    max_workers = int(state.get("max_workers") or DEFAULT_MAX_WORKERS)
    state["summary"] = {
        "active_workers": active_workers,
        "max_workers": max_workers,
        "queued_milestones": queued_milestones,
        "running_milestones": running_milestones,
        "qa_blocked": qa_blocked,
        "ready_to_deliver": ready_to_deliver,
        "revenue_at_risk": revenue_at_risk,
        "currency": currency,
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
    command = f"timeout {int(timeout)} {codex_command} exec --skip-git-repo-check < {shlex.quote(str(prompt_path))}"
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
            break
    for worker in state["workers"]:
        if worker.get("id") == worker_id:
            worker["status"] = "idle" if result["ok"] else "failed"
            worker["proof_url"] = result["artifact_urls"][-1] if result["artifact_urls"] else None
            worker["failure_count"] = int(worker.get("failure_count") or 0) + (0 if result["ok"] else 1)
            break
    state["qa_reviews"].append({"id": stable_id("qa", milestone_id, result.get("finished_at")), "milestone_id": milestone_id, "reviewer": "factory-runtime", "status": "passed" if result["ok"] else "failed", "checks_passed": 3 if result["ok"] else 1, "checks_total": 3, "notes": result.get("notes") or "", "updated_at": utc_now()})


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
        enqueue(argparse.Namespace(state=str(state_path), json="", source="selftest", client_signal="Need a proof artifact", offer="Factory Selftest", budget=10, currency="USD", stage="proof"))
        run_once(argparse.Namespace(state=str(state_path), artifact_dir=str(artifact_dir), max_workers=1, limit=1, timeout=5, codex="printf SELFTEST_OK #", role="proof"))
        data = load_state(state_path)
        assert data["summary"]["qa_blocked"] == 0, data
        assert data["qa_reviews"], data
    print("SELFTEST_OK")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the iPOP/Samantha parallel work factory.")
    parser.add_argument("--state", default=str(DEFAULT_STATE_PATH))
    sub = parser.add_subparsers(dest="command", required=True)
    p_init = sub.add_parser("init")
    p_init.add_argument("--max-workers", type=int, default=DEFAULT_MAX_WORKERS)
    p_init.set_defaults(func=init)
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
