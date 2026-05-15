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
          }]
        }
        """#.data(using: .utf8)!

        let dashboard = try JSONDecoder().decode(FactoryDashboard.self, from: payload)

        #expect(dashboard.hasLiveState)
        #expect(dashboard.summary.activeWorkers == 18)
        #expect(dashboard.summary.workerUtilization == 0.45)
        #expect(dashboard.queues.first?.stage == .executing)
        #expect(dashboard.queues.first?.isBreachingSLA == false)
        #expect(dashboard.workers.first?.role == .fulfillment)
        #expect(dashboard.milestones.first?.qaStatus == .pending)
        #expect(dashboard.payments.first?.status == .depositPaid)
    }
}
