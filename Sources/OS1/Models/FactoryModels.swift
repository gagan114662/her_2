import Foundation

struct FactoryDashboard: Codable, Equatable, Sendable {
    var statePath: String
    var generatedAt: String
    var summary: FactorySummary
    var queues: [FactoryQueue]
    var workers: [FactoryWorker]
    var milestones: [FactoryMilestone]
    var qaReviews: [FactoryQAReview]
    var payments: [FactoryPayment]

    var hasLiveState: Bool {
        !queues.isEmpty || !workers.isEmpty || !milestones.isEmpty || !qaReviews.isEmpty || !payments.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case statePath = "state_path"
        case generatedAt = "generated_at"
        case summary
        case queues
        case workers
        case milestones
        case qaReviews = "qa_reviews"
        case payments
    }
}

struct FactorySummary: Codable, Equatable, Sendable {
    var activeWorkers: Int
    var maxWorkers: Int
    var queuedMilestones: Int
    var runningMilestones: Int
    var qaBlocked: Int
    var readyToDeliver: Int
    var revenueAtRisk: Double
    var currency: String

    var workerUtilization: Double {
        guard maxWorkers > 0 else { return 0 }
        return min(1, max(0, Double(activeWorkers) / Double(maxWorkers)))
    }

    enum CodingKeys: String, CodingKey {
        case activeWorkers = "active_workers"
        case maxWorkers = "max_workers"
        case queuedMilestones = "queued_milestones"
        case runningMilestones = "running_milestones"
        case qaBlocked = "qa_blocked"
        case readyToDeliver = "ready_to_deliver"
        case revenueAtRisk = "revenue_at_risk"
        case currency
    }
}

struct FactoryQueue: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var stage: FactoryStage
    var count: Int
    var oldestAgeMinutes: Int?
    var slaMinutes: Int?

    var isBreachingSLA: Bool {
        guard let oldestAgeMinutes, let slaMinutes else { return false }
        return oldestAgeMinutes > slaMinutes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case stage
        case count
        case oldestAgeMinutes = "oldest_age_minutes"
        case slaMinutes = "sla_minutes"
    }
}

enum FactoryStage: String, Codable, CaseIterable, Sendable {
    case demand
    case proof
    case paid
    case executing
    case qa
    case delivery
    case blocked

    var title: String {
        switch self {
        case .demand: "Demand"
        case .proof: "Proof"
        case .paid: "Paid"
        case .executing: "Executing"
        case .qa: "QA"
        case .delivery: "Delivery"
        case .blocked: "Blocked"
        }
    }
}

struct FactoryWorker: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var role: FactoryWorkerRole
    var status: FactoryWorkerStatus
    var currentMilestoneID: String?
    var startedAt: String?
    var workspaceURL: String?
    var proofURL: String?
    var failureCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role
        case status
        case currentMilestoneID = "current_milestone_id"
        case startedAt = "started_at"
        case workspaceURL = "workspace_url"
        case proofURL = "proof_url"
        case failureCount = "failure_count"
    }
}

enum FactoryWorkerRole: String, Codable, CaseIterable, Sendable {
    case scanner
    case qualifier
    case proof
    case fulfillment
    case qa
    case delivery
    case payment

    var title: String {
        switch self {
        case .scanner: "Scanner"
        case .qualifier: "Qualifier"
        case .proof: "Proof"
        case .fulfillment: "Fulfillment"
        case .qa: "QA"
        case .delivery: "Delivery"
        case .payment: "Payment"
        }
    }
}

enum FactoryWorkerStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case queued
    case running
    case waiting
    case blocked
    case failed

    var title: String {
        switch self {
        case .idle: "Idle"
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .failed: "Failed"
        }
    }
}

struct FactoryMilestone: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String
    var clientSignal: String
    var offer: String
    var budget: Double
    var currency: String
    var stage: FactoryStage
    var assignedWorkerID: String?
    var qaStatus: FactoryQAStatus
    var paymentStatus: FactoryPaymentStatus
    var proofRequired: [String]
    var artifactURLs: [String]
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case clientSignal = "client_signal"
        case offer
        case budget
        case currency
        case stage
        case assignedWorkerID = "assigned_worker_id"
        case qaStatus = "qa_status"
        case paymentStatus = "payment_status"
        case proofRequired = "proof_required"
        case artifactURLs = "artifact_urls"
        case updatedAt = "updated_at"
    }
}

enum FactoryQAStatus: String, Codable, CaseIterable, Sendable {
    case notStarted = "not_started"
    case pending
    case passed
    case failed
    case needsHuman = "needs_human"

    var title: String {
        switch self {
        case .notStarted: "Not Started"
        case .pending: "Pending"
        case .passed: "Passed"
        case .failed: "Failed"
        case .needsHuman: "Needs Human"
        }
    }
}

enum FactoryPaymentStatus: String, Codable, CaseIterable, Sendable {
    case unpaid
    case depositPaid = "deposit_paid"
    case paid
    case disputed
    case refunded

    var title: String {
        switch self {
        case .unpaid: "Unpaid"
        case .depositPaid: "Deposit Paid"
        case .paid: "Paid"
        case .disputed: "Disputed"
        case .refunded: "Refunded"
        }
    }
}

struct FactoryQAReview: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var milestoneID: String
    var reviewer: String
    var status: FactoryQAStatus
    var checksPassed: Int
    var checksTotal: Int
    var notes: String
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case milestoneID = "milestone_id"
        case reviewer
        case status
        case checksPassed = "checks_passed"
        case checksTotal = "checks_total"
        case notes
        case updatedAt = "updated_at"
    }
}

struct FactoryPayment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var milestoneID: String
    var stripeObjectID: String?
    var amount: Double
    var currency: String
    var status: FactoryPaymentStatus
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case milestoneID = "milestone_id"
        case stripeObjectID = "stripe_object_id"
        case amount
        case currency
        case status
        case updatedAt = "updated_at"
    }
}
