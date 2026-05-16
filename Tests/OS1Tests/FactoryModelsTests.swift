import Foundation
import Testing
@testable import OS1

struct FactoryModelsTests {
    @Test
    func dashboardPayloadDecodesParallelAgentFactoryState() throws {
        let payload = #"""
        {
          "state_path": "/home/user/ipop-factory.json",
          "generated_at": "2026-05-15T17:30:00Z",
          "summary": {
            "active_workers": 18,
            "max_workers": 40,
            "found_opportunities": 25,
            "qualified_opportunities": 9,
            "drafted_opportunities": 5,
            "approved_to_submit": 1,
            "queued_milestones": 120,
            "running_milestones": 18,
            "qa_blocked": 3,
            "ready_to_deliver": 7,
            "revenue_at_risk": 9500,
            "currency": "USD"
          },
          "queues": [{
            "id": "executing",
            "name": "Executing",
            "stage": "executing",
            "count": 18,
            "oldest_age_minutes": 14,
            "sla_minutes": 45
          }],
          "workers": [{
            "id": "worker_stripe_1",
            "name": "stripe-worker-1",
            "role": "fulfillment",
            "status": "running",
            "current_milestone_id": "ms_1",
            "started_at": "2026-05-15T17:10:00Z",
            "workspace_url": "https://samantha.example/session/1",
            "proof_url": "https://drive.example/proof",
            "failure_count": 0
          }],
          "milestones": [{
            "id": "ms_1",
            "source": "public-demand",
            "client_signal": "Broken Stripe webhook",
            "offer": "Stripe Checkout Repair",
            "budget": 300,
            "currency": "USD",
            "stage": "executing",
            "assigned_worker_id": "worker_stripe_1",
            "qa_status": "pending",
            "payment_status": "deposit_paid",
            "proof_required": ["repro log", "passing webhook test"],
            "artifact_urls": ["https://github.example/pr/1"],
            "updated_at": "2026-05-15T17:20:00Z"
          }],
          "qa_reviews": [{
            "id": "qa_1",
            "milestone_id": "ms_1",
            "reviewer": "qa-agent-1",
            "status": "pending",
            "checks_passed": 4,
            "checks_total": 6,
            "notes": "Waiting on webhook replay.",
            "updated_at": "2026-05-15T17:25:00Z"
          }],
          "payments": [{
            "id": "pay_1",
            "milestone_id": "ms_1",
            "stripe_object_id": "cs_live_123",
            "amount": 150,
            "currency": "USD",
            "status": "deposit_paid",
            "updated_at": "2026-05-15T17:12:00Z"
          }],
          "opportunities": [{
            "id": "opp_1",
            "source": "remoteok",
            "source_url": "https://remoteok.com/remote-jobs/1",
            "platform": "RemoteOK",
            "buyer": "SaaS founder",
            "title": "Fix Stripe webhook",
            "raw_requirement": "Need a developer to fix checkout.session.completed and provide replay proof. Budget $450.",
            "normalized_deliverables": ["Webhook fix", "Replay proof"],
            "acceptance_criteria": ["Stripe event replays cleanly"],
            "budget": 450,
            "currency": "USD",
            "urgency": "fast turnaround",
            "contact_route": "platform",
            "required_tools": ["Stripe", "API"],
            "account_readiness": "source-only; draft package can be prepared",
            "risk_flags": [],
            "status": "approved_to_submit",
            "score": {
              "overall": 84,
              "payment_probability": 77,
              "time_to_cash": 82,
              "payout": 82,
              "effort": 76,
              "buyer_trust": 77,
              "requirement_clarity": 90,
              "competition": 48,
              "capability_fit": 84,
              "account_readiness": 72,
              "risk": 12,
              "reasons": ["fits Stripe capability", "clear proof target"]
            },
            "proposal_package": {
              "buyer_problem_summary": "Webhook needs to work with proof.",
              "exact_deliverables": ["Webhook fix", "Replay proof"],
              "work_plan": ["Reproduce", "Patch", "Replay"],
              "milestone_split": ["Proof milestone $225", "Delivery $225"],
              "access_needed": ["Stripe test events"],
              "proof_plan": ["Replay checkout.session.completed"],
              "pricing_recommendation": "Quote $450 with proof-first milestone.",
              "proposal_text": "I can deliver the webhook fix with replay proof."
            },
            "execution_plan": ["Reproduce", "Patch", "Replay"],
            "evidence": ["ranked from live source"],
            "updated_at": "2026-05-15T17:12:00Z"
          }],
          "revenue_ledger": [{
            "id": "ledger_1",
            "opportunity_id": "opp_1",
            "milestone_id": "ms_1",
            "projected_value": 450,
            "quoted_value": 450,
            "accepted_value": 225,
            "invoiced_value": 0,
            "pending_payment": 0,
            "platform_fees": 0,
            "net_received": 0,
            "currency": "USD",
            "payment_status": "unpaid",
            "proof_url": "https://drive.example/proof",
            "blocker_reason": "Awaiting buyer acceptance",
            "updated_at": "2026-05-15T17:12:00Z"
          }],
          "events": [{
            "id": "evt_1",
            "timestamp": "2026-05-15T17:12:00Z",
            "subject_id": "opp_1",
            "action": "approved_to_submit",
            "evidence": "Matched approval rule; no external submit performed"
          }],
          "approval_rules": [{
            "id": "rule_1",
            "source": "remoteok",
            "platform": "RemoteOK",
            "max_risk": 35,
            "max_quoted_value": 1000,
            "allowed_actions": ["mark approval-ready"],
            "enabled": true,
            "created_at": "2026-05-15T17:12:00Z"
          }]
        }
        """#.data(using: .utf8)!

        let dashboard = try JSONDecoder().decode(FactoryDashboard.self, from: payload)

        #expect(dashboard.hasLiveState)
        #expect(dashboard.summary.activeWorkers == 18)
        #expect(dashboard.summary.workerUtilization == 0.45)
        #expect(dashboard.summary.foundOpportunities == 25)
        #expect(dashboard.summary.approvedToSubmit == 1)
        #expect(dashboard.opportunities.first?.status == .approvedToSubmit)
        #expect(dashboard.opportunities.first?.score.overall == 84)
        #expect(dashboard.opportunities.first?.proposalPackage?.proposalText.contains("webhook fix") == true)
        #expect(dashboard.revenueLedger.first?.opportunityID == "opp_1")
        #expect(dashboard.events.first?.action == "approved_to_submit")
        #expect(dashboard.approvalRules.first?.enabled == true)
        #expect(dashboard.queues.first?.stage == .executing)
        #expect(dashboard.queues.first?.isBreachingSLA == false)
        #expect(dashboard.workers.first?.role == .fulfillment)
        #expect(dashboard.milestones.first?.qaStatus == .pending)
        #expect(dashboard.payments.first?.status == .depositPaid)
    }
}
