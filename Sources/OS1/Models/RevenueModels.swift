import Foundation

struct RevenueDashboard: Codable, Equatable, Sendable {
    var logPath: String
    var generatedAt: String
    var totals: RevenueTotals
    var workflows: [RevenueWorkflowSummary]
    var events: [RevenueEvent]
    var reviews: [RevenueReview]
    var fleet: [RevenueFleetComputer]
    var setup: RevenueSetupStatus

    var hasRevenueLog: Bool { !events.isEmpty || !workflows.isEmpty || !reviews.isEmpty }

    enum CodingKeys: String, CodingKey {
        case logPath = "log_path"
        case generatedAt = "generated_at"
        case totals
        case workflows
        case events
        case reviews
        case fleet
        case setup
    }
}

struct RevenueTotals: Codable, Equatable, Sendable {
    var today: Double
    var week: Double
    var month: Double
    var allTime: Double
    var currency: String
    var daily: [RevenueDailyTotal]

    enum CodingKeys: String, CodingKey {
        case today
        case week
        case month
        case allTime = "all_time"
        case currency
        case daily
    }
}

struct RevenueDailyTotal: Codable, Equatable, Identifiable, Sendable {
    var date: String
    var amount: Double

    var id: String { date }
}

struct RevenueWorkflowSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var revenue: Double
    var currency: String
    var lastEventAt: String?
    var workflowURL: String?
    var verificationURL: String?
    var status: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case revenue
        case currency
        case lastEventAt = "last_event_at"
        case workflowURL = "workflow_url"
        case verificationURL = "verification_url"
        case status
    }
}

struct RevenueEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: String?
    var workflow: String
    var platform: String?
    var amount: Double
    var currency: String
    var action: String?
    var postURL: String?
    var flowID: String?
    var verificationURL: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case workflow
        case platform
        case amount
        case currency
        case action
        case postURL = "post_url"
        case flowID = "flow_id"
        case verificationURL = "verification_url"
        case error
    }
}

struct RevenueReview: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: String?
    var workflow: String
    var verdict: String
    var actionTaken: String
    var revenue: Double
    var clicks: Int?
    var conversions: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case workflow
        case verdict
        case actionTaken = "action_taken"
        case revenue
        case clicks
        case conversions
    }
}

struct RevenueFleetComputer: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var purpose: String
    var status: String
    var uptime: String
    var revenue: Double
    var currency: String
    var failureCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case purpose
        case status
        case uptime
        case revenue
        case currency
        case failureCount = "failure_count"
    }
}

struct RevenueSetupStatus: Codable, Equatable, Sendable {
    var missionExists: Bool
    var revenueLogExists: Bool
    var reviewAgentExists: Bool
    var n8nHealthy: Bool
    var n8nServiceActive: Bool
    var n8nServiceEnabled: Bool
    var cloudflaredEnabled: Bool
    var publicURL: String?
    var cronEntries: [String]
    var aitoearnConfigured: Bool
    var socialAccountsConnected: Bool

    enum CodingKeys: String, CodingKey {
        case missionExists = "mission_exists"
        case revenueLogExists = "revenue_log_exists"
        case reviewAgentExists = "review_agent_exists"
        case n8nHealthy = "n8n_healthy"
        case n8nServiceActive = "n8n_service_active"
        case n8nServiceEnabled = "n8n_service_enabled"
        case cloudflaredEnabled = "cloudflared_enabled"
        case publicURL = "public_url"
        case cronEntries = "cron_entries"
        case aitoearnConfigured = "aitoearn_configured"
        case socialAccountsConnected = "social_accounts_connected"
    }
}

struct RevenueSetupResult: Codable, Equatable, Sendable {
    var success: Bool
    var stepsDone: [String]
    var errors: [String]
    var revenueLogPath: String
    var missionPath: String

    enum CodingKeys: String, CodingKey {
        case success
        case stepsDone = "steps_done"
        case errors
        case revenueLogPath = "revenue_log_path"
        case missionPath = "mission_path"
    }
}
