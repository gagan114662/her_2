import Foundation

struct FactoryDashboard: Codable, Equatable, Sendable {
    var statePath: String
    var generatedAt: String
    var summary: FactorySummary
    var opportunities: [RemoteJobOpportunity]
    var queues: [FactoryQueue]
    var workers: [FactoryWorker]
    var milestones: [FactoryMilestone]
    var qaReviews: [FactoryQAReview]
    var payments: [FactoryPayment]
    var revenueLedger: [FactoryRevenueLedgerEntry]
    var events: [FactoryEvent]
    var approvalRules: [FactoryApprovalRule]

    var hasLiveState: Bool {
        !opportunities.isEmpty || !queues.isEmpty || !workers.isEmpty || !milestones.isEmpty || !qaReviews.isEmpty || !payments.isEmpty || !revenueLedger.isEmpty || !events.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case statePath = "state_path"
        case generatedAt = "generated_at"
        case summary
        case opportunities
        case queues
        case workers
        case milestones
        case qaReviews = "qa_reviews"
        case payments
        case revenueLedger = "revenue_ledger"
        case events
        case approvalRules = "approval_rules"
    }

    init(
        statePath: String,
        generatedAt: String,
        summary: FactorySummary,
        opportunities: [RemoteJobOpportunity] = [],
        queues: [FactoryQueue],
        workers: [FactoryWorker],
        milestones: [FactoryMilestone],
        qaReviews: [FactoryQAReview],
        payments: [FactoryPayment],
        revenueLedger: [FactoryRevenueLedgerEntry] = [],
        events: [FactoryEvent] = [],
        approvalRules: [FactoryApprovalRule] = []
    ) {
        self.statePath = statePath
        self.generatedAt = generatedAt
        self.summary = summary
        self.opportunities = opportunities
        self.queues = queues
        self.workers = workers
        self.milestones = milestones
        self.qaReviews = qaReviews
        self.payments = payments
        self.revenueLedger = revenueLedger
        self.events = events
        self.approvalRules = approvalRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statePath = try container.decode(String.self, forKey: .statePath)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        summary = try container.decode(FactorySummary.self, forKey: .summary)
        opportunities = try container.decodeIfPresent([RemoteJobOpportunity].self, forKey: .opportunities) ?? []
        queues = try container.decodeIfPresent([FactoryQueue].self, forKey: .queues) ?? []
        workers = try container.decodeIfPresent([FactoryWorker].self, forKey: .workers) ?? []
        milestones = try container.decodeIfPresent([FactoryMilestone].self, forKey: .milestones) ?? []
        qaReviews = try container.decodeIfPresent([FactoryQAReview].self, forKey: .qaReviews) ?? []
        payments = try container.decodeIfPresent([FactoryPayment].self, forKey: .payments) ?? []
        revenueLedger = try container.decodeIfPresent([FactoryRevenueLedgerEntry].self, forKey: .revenueLedger) ?? []
        events = try container.decodeIfPresent([FactoryEvent].self, forKey: .events) ?? []
        approvalRules = try container.decodeIfPresent([FactoryApprovalRule].self, forKey: .approvalRules) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(statePath, forKey: .statePath)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(summary, forKey: .summary)
        try container.encode(opportunities, forKey: .opportunities)
        try container.encode(queues, forKey: .queues)
        try container.encode(workers, forKey: .workers)
        try container.encode(milestones, forKey: .milestones)
        try container.encode(qaReviews, forKey: .qaReviews)
        try container.encode(payments, forKey: .payments)
        try container.encode(revenueLedger, forKey: .revenueLedger)
        try container.encode(events, forKey: .events)
        try container.encode(approvalRules, forKey: .approvalRules)
    }
}

struct FactorySummary: Codable, Equatable, Sendable {
    var activeWorkers: Int
    var maxWorkers: Int
    var foundOpportunities: Int
    var qualifiedOpportunities: Int
    var draftedOpportunities: Int
    var approvedToSubmit: Int
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
        case foundOpportunities = "found_opportunities"
        case qualifiedOpportunities = "qualified_opportunities"
        case draftedOpportunities = "drafted_opportunities"
        case approvedToSubmit = "approved_to_submit"
        case queuedMilestones = "queued_milestones"
        case runningMilestones = "running_milestones"
        case qaBlocked = "qa_blocked"
        case readyToDeliver = "ready_to_deliver"
        case revenueAtRisk = "revenue_at_risk"
        case currency
    }

    init(
        activeWorkers: Int,
        maxWorkers: Int,
        foundOpportunities: Int = 0,
        qualifiedOpportunities: Int = 0,
        draftedOpportunities: Int = 0,
        approvedToSubmit: Int = 0,
        queuedMilestones: Int,
        runningMilestones: Int,
        qaBlocked: Int,
        readyToDeliver: Int,
        revenueAtRisk: Double,
        currency: String
    ) {
        self.activeWorkers = activeWorkers
        self.maxWorkers = maxWorkers
        self.foundOpportunities = foundOpportunities
        self.qualifiedOpportunities = qualifiedOpportunities
        self.draftedOpportunities = draftedOpportunities
        self.approvedToSubmit = approvedToSubmit
        self.queuedMilestones = queuedMilestones
        self.runningMilestones = runningMilestones
        self.qaBlocked = qaBlocked
        self.readyToDeliver = readyToDeliver
        self.revenueAtRisk = revenueAtRisk
        self.currency = currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeWorkers = try container.decode(Int.self, forKey: .activeWorkers)
        maxWorkers = try container.decode(Int.self, forKey: .maxWorkers)
        foundOpportunities = try container.decodeIfPresent(Int.self, forKey: .foundOpportunities) ?? 0
        qualifiedOpportunities = try container.decodeIfPresent(Int.self, forKey: .qualifiedOpportunities) ?? 0
        draftedOpportunities = try container.decodeIfPresent(Int.self, forKey: .draftedOpportunities) ?? 0
        approvedToSubmit = try container.decodeIfPresent(Int.self, forKey: .approvedToSubmit) ?? 0
        queuedMilestones = try container.decode(Int.self, forKey: .queuedMilestones)
        runningMilestones = try container.decode(Int.self, forKey: .runningMilestones)
        qaBlocked = try container.decode(Int.self, forKey: .qaBlocked)
        readyToDeliver = try container.decode(Int.self, forKey: .readyToDeliver)
        revenueAtRisk = try container.decode(Double.self, forKey: .revenueAtRisk)
        currency = try container.decode(String.self, forKey: .currency)
    }
}

struct RemoteJobOpportunity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String
    var sourceURL: String
    var platform: String
    var buyer: String
    var title: String
    var rawRequirement: String
    var normalizedDeliverables: [String]
    var acceptanceCriteria: [String]
    var budget: Double
    var currency: String
    var urgency: String
    var contactRoute: String
    var requiredTools: [String]
    var accountReadiness: String
    var riskFlags: [String]
    var status: RemoteJobOpportunityStatus
    var score: RemoteJobScore
    var proposalPackage: RemoteJobProposalPackage?
    var executionPlan: [String]
    var payment: FactoryRevenueLedgerEntry?
    var evidence: [String]
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case sourceURL = "source_url"
        case platform
        case buyer
        case title
        case rawRequirement = "raw_requirement"
        case normalizedDeliverables = "normalized_deliverables"
        case acceptanceCriteria = "acceptance_criteria"
        case budget
        case currency
        case urgency
        case contactRoute = "contact_route"
        case requiredTools = "required_tools"
        case accountReadiness = "account_readiness"
        case riskFlags = "risk_flags"
        case status
        case score
        case proposalPackage = "proposal_package"
        case executionPlan = "execution_plan"
        case payment
        case evidence
        case updatedAt = "updated_at"
    }
}

enum RemoteJobOpportunityStatus: String, Codable, CaseIterable, Sendable {
    case found
    case parsed
    case rejected
    case qualified
    case ranked
    case drafted
    case approvedToSubmit = "approved_to_submit"
    case submitted
    case accepted
    case inProgress = "in_progress"
    case qa
    case delivered
    case invoiced
    case paid
    case closed

    var title: String {
        switch self {
        case .found: "Found"
        case .parsed: "Parsed"
        case .rejected: "Rejected"
        case .qualified: "Qualified"
        case .ranked: "Ranked"
        case .drafted: "Drafted"
        case .approvedToSubmit: "Approved"
        case .submitted: "Submitted"
        case .accepted: "Accepted"
        case .inProgress: "In Progress"
        case .qa: "QA"
        case .delivered: "Delivered"
        case .invoiced: "Invoiced"
        case .paid: "Paid"
        case .closed: "Closed"
        }
    }
}

struct RemoteJobScore: Codable, Equatable, Sendable {
    var overall: Int
    var paymentProbability: Int
    var timeToCash: Int
    var payout: Int
    var effort: Int
    var buyerTrust: Int
    var requirementClarity: Int
    var competition: Int
    var capabilityFit: Int
    var accountReadiness: Int
    var risk: Int
    var reasons: [String]

    enum CodingKeys: String, CodingKey {
        case overall
        case paymentProbability = "payment_probability"
        case timeToCash = "time_to_cash"
        case payout
        case effort
        case buyerTrust = "buyer_trust"
        case requirementClarity = "requirement_clarity"
        case competition
        case capabilityFit = "capability_fit"
        case accountReadiness = "account_readiness"
        case risk
        case reasons
    }
}

struct RemoteJobProposalPackage: Codable, Equatable, Sendable {
    var buyerProblemSummary: String
    var exactDeliverables: [String]
    var workPlan: [String]
    var milestoneSplit: [String]
    var accessNeeded: [String]
    var proofPlan: [String]
    var pricingRecommendation: String
    var proposalText: String

    enum CodingKeys: String, CodingKey {
        case buyerProblemSummary = "buyer_problem_summary"
        case exactDeliverables = "exact_deliverables"
        case workPlan = "work_plan"
        case milestoneSplit = "milestone_split"
        case accessNeeded = "access_needed"
        case proofPlan = "proof_plan"
        case pricingRecommendation = "pricing_recommendation"
        case proposalText = "proposal_text"
    }
}

struct FactoryRevenueLedgerEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var opportunityID: String?
    var milestoneID: String?
    var projectedValue: Double
    var quotedValue: Double
    var acceptedValue: Double
    var invoicedValue: Double
    var pendingPayment: Double
    var platformFees: Double
    var netReceived: Double
    var currency: String
    var paymentStatus: FactoryPaymentStatus
    var proofURL: String?
    var blockerReason: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case opportunityID = "opportunity_id"
        case milestoneID = "milestone_id"
        case projectedValue = "projected_value"
        case quotedValue = "quoted_value"
        case acceptedValue = "accepted_value"
        case invoicedValue = "invoiced_value"
        case pendingPayment = "pending_payment"
        case platformFees = "platform_fees"
        case netReceived = "net_received"
        case currency
        case paymentStatus = "payment_status"
        case proofURL = "proof_url"
        case blockerReason = "blocker_reason"
        case updatedAt = "updated_at"
    }
}

struct FactoryEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: String
    var subjectID: String
    var action: String
    var evidence: String

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case subjectID = "subject_id"
        case action
        case evidence
    }
}

struct FactoryApprovalRule: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String
    var platform: String
    var maxRisk: Int
    var maxQuotedValue: Double
    var allowedActions: [String]
    var enabled: Bool
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case platform
        case maxRisk = "max_risk"
        case maxQuotedValue = "max_quoted_value"
        case allowedActions = "allowed_actions"
        case enabled
        case createdAt = "created_at"
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
