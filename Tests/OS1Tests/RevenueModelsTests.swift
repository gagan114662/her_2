import Foundation
import Testing
@testable import OS1

struct RevenueModelsTests {
    @Test
    func dashboardPayloadDecodesRevenueFleetAndSetupState() throws {
        let payload = #"""
        {
          "log_path": "/home/user/revenue-log.json",
          "generated_at": "2026-05-14T12:00:00Z",
          "totals": {
            "today": 25,
            "week": 75,
            "month": 125,
            "all_time": 250,
            "currency": "USD",
            "daily": [{"date": "2026-05-14", "amount": 25}]
          },
          "workflows": [{
            "id": "linkedin-content",
            "name": "LinkedIn Content",
            "revenue": 125,
            "currency": "USD",
            "last_event_at": "2026-05-14T11:00:00Z",
            "workflow_url": "https://samantha.example/n8n/workflow/1",
            "verification_url": "https://linkedin.example/post",
            "status": "active"
          }],
          "events": [{
            "id": "evt_1",
            "timestamp": "2026-05-14T11:00:00Z",
            "workflow": "LinkedIn Content",
            "platform": "linkedin",
            "amount": 25,
            "currency": "USD",
            "action": "posted",
            "post_url": "https://linkedin.example/post",
            "flow_id": "flow_1",
            "verification_url": "https://linkedin.example/post",
            "error": null
          }],
          "reviews": [{
            "id": "review_1",
            "timestamp": "2026-05-14T10:00:00Z",
            "workflow": "LinkedIn Content",
            "verdict": "improve",
            "action_taken": "created a second variation",
            "revenue": 125,
            "clicks": 40,
            "conversions": 2
          }],
          "fleet": [{
            "id": "vm_1",
            "name": "linkedin-agent-1",
            "purpose": "LinkedIn content workflow",
            "status": "running",
            "uptime": "3h",
            "revenue": 125,
            "currency": "USD",
            "failure_count": 0
          }],
          "setup": {
            "mission_exists": true,
            "revenue_log_exists": true,
            "review_agent_exists": true,
            "n8n_healthy": true,
            "n8n_service_active": true,
            "n8n_service_enabled": true,
            "cloudflared_enabled": true,
            "public_url": "https://samantha.example",
            "cron_entries": ["0 7 * * * /home/user/revenue-agent.sh"],
            "aitoearn_configured": true,
            "social_accounts_connected": true
          }
        }
        """#.data(using: .utf8)!

        let dashboard = try JSONDecoder().decode(RevenueDashboard.self, from: payload)

        #expect(dashboard.hasRevenueLog)
        #expect(dashboard.totals.today == 25)
        #expect(dashboard.workflows.first?.workflowURL == "https://samantha.example/n8n/workflow/1")
        #expect(dashboard.events.first?.flowID == "flow_1")
        #expect(dashboard.reviews.first?.verdict == "improve")
        #expect(dashboard.fleet.first?.name == "linkedin-agent-1")
        #expect(dashboard.setup.publicURL == "https://samantha.example")
    }
}
