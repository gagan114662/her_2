import SwiftUI

struct FactoryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        HermesPageContainer(width: .analytics) {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let error = appState.factoryError {
                    errorPanel(error)
                }

                if appState.isLoadingFactory, appState.factoryDashboard == nil {
                    HermesSurfacePanel {
                        HermesLoadingState(label: "Loading factory state...", minHeight: 320)
                    }
                } else if let dashboard = appState.factoryDashboard {
                    dashboardContent(dashboard)
                } else {
                    emptyPanel
                }
            }
        }
        .task(id: appState.activeConnectionID) {
            await appState.loadFactoryDashboard()
        }
    }

    private var header: some View {
        HermesPageHeader(
            title: "Factory",
            subtitle: "A Conductor-inspired control tower for qualified paid remote jobs: discovery, scoring, proposal packs, workers, QA, delivery, and cash state."
        ) {
            HermesRefreshButton(isRefreshing: appState.isRefreshingFactory) {
                Task { await appState.refreshFactoryDashboard(manual: true) }
            }
            .disabled(appState.activeConnection == nil)
        }
    }

    private func dashboardContent(_ dashboard: FactoryDashboard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryPanel(dashboard.summary)
            opportunitiesPanel(dashboard.opportunities)
            approvalPanel(dashboard.opportunities, rules: dashboard.approvalRules)
            queuesPanel(dashboard.queues)

            HStack(alignment: .top, spacing: 16) {
                workersPanel(dashboard.workers)
                    .frame(minWidth: 460, maxWidth: .infinity, alignment: .top)
                milestonesPanel(dashboard.milestones)
                    .frame(minWidth: 520, maxWidth: .infinity, alignment: .top)
            }

            HStack(alignment: .top, spacing: 16) {
                qaPanel(dashboard.qaReviews)
                    .frame(minWidth: 460, maxWidth: .infinity, alignment: .top)
                paymentsPanel(dashboard.payments)
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
            }

            HStack(alignment: .top, spacing: 16) {
                ledgerPanel(dashboard.revenueLedger)
                    .frame(minWidth: 460, maxWidth: .infinity, alignment: .top)
                eventsPanel(dashboard.events)
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
            }

            statePathPanel(dashboard)
        }
    }

    private func summaryPanel(_ summary: FactorySummary) -> some View {
        HermesSurfacePanel(title: "Parallel Capacity", subtitle: "How much agent labor Samantha can keep moving at once.") {
            HStack(spacing: 12) {
                metricTile("Workers", "\(summary.activeWorkers)/\(summary.maxWorkers)", systemImage: "person.3.sequence")
                metricTile("Leads", "\(summary.foundOpportunities)", systemImage: "scope")
                metricTile("Qualified", "\(summary.qualifiedOpportunities)", systemImage: "line.3.horizontal.decrease.circle")
                metricTile("Drafted", "\(summary.draftedOpportunities)", systemImage: "doc.text")
                metricTile("Approved", "\(summary.approvedToSubmit)", systemImage: "paperplane")
                metricTile("Queued", "\(summary.queuedMilestones)", systemImage: "tray.full")
                metricTile("Running", "\(summary.runningMilestones)", systemImage: "play.circle")
                metricTile("QA Blocked", "\(summary.qaBlocked)", systemImage: "exclamationmark.shield")
                metricTile("Ready", "\(summary.readyToDeliver)", systemImage: "shippingbox")
                metricTile("At Risk", amount(summary.revenueAtRisk, summary.currency), systemImage: "creditcard")
            }

            ProgressView(value: summary.workerUtilization)
                .tint(theme.palette.success)
        }
    }

    private func opportunitiesPanel(_ opportunities: [RemoteJobOpportunity]) -> some View {
        HermesSurfacePanel(title: "Qualified Remote Jobs", subtitle: "JustHireMe-style discovery, quality gates, money scoring, and requirement-specific proposal packs.") {
            if opportunities.isEmpty {
                ContentUnavailableView("No paid jobs discovered", systemImage: "magnifyingglass", description: Text("Run Samantha discovery to populate requirement-driven remote work opportunities."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 8) {
                    ForEach(opportunities.prefix(12)) { opportunity in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(opportunity.title)
                                        .font(.os1Body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.os1OnCoralPrimary)
                                        .lineLimit(1)
                                    Text(opportunity.buyer + " · " + opportunity.platform)
                                        .font(.os1SmallCaps)
                                        .foregroundStyle(.os1OnCoralSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(amount(opportunity.budget, opportunity.currency))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.os1OnCoralPrimary)
                                HermesBadge(text: "\(opportunity.score.overall)", tint: tint(for: opportunity.status))
                            }

                            Text(opportunity.rawRequirement)
                                .font(.os1SmallCaps)
                                .foregroundStyle(.os1OnCoralSecondary)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                HermesBadge(text: opportunity.status.title, tint: tint(for: opportunity.status))
                                HermesBadge(text: "Pay \(opportunity.score.paymentProbability)", tint: theme.palette.success)
                                HermesBadge(text: "Risk \(opportunity.score.risk)", tint: opportunity.score.risk > 50 ? theme.palette.danger : theme.palette.warning)
                                if !opportunity.requiredTools.isEmpty {
                                    Text(opportunity.requiredTools.prefix(3).joined(separator: ", "))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.os1OnCoralMuted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func approvalPanel(_ opportunities: [RemoteJobOpportunity], rules: [FactoryApprovalRule]) -> some View {
        let awaiting = opportunities.filter { [.drafted, .approvedToSubmit].contains($0.status) }
        return HermesSurfacePanel(title: "Approval Boundary", subtitle: "External submissions stay gated unless an explicit source rule matches.") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ready Packages")
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                    if awaiting.isEmpty {
                        Text("No proposal packs are waiting for approval.")
                            .font(.os1Body)
                            .foregroundStyle(.os1OnCoralMuted)
                    } else {
                        ForEach(awaiting.prefix(5)) { opportunity in
                            HStack {
                                Text(opportunity.title)
                                    .font(.os1Body)
                                    .lineLimit(1)
                                Spacer()
                                HermesBadge(text: opportunity.status.title, tint: tint(for: opportunity.status))
                            }
                            .padding(8)
                            .background(theme.palette.darkOverlay.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Submit Rules")
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                    if rules.isEmpty {
                        Text("Draft-only mode. Add approval rules on Samantha before auto-submit.")
                            .font(.os1Body)
                            .foregroundStyle(.os1OnCoralMuted)
                    } else {
                        ForEach(rules.prefix(5)) { rule in
                            HStack {
                                Text(rule.platform + " · risk ≤ \(rule.maxRisk)")
                                    .font(.os1Body)
                                    .lineLimit(1)
                                Spacer()
                                HermesBadge(text: rule.enabled ? "Enabled" : "Paused", tint: rule.enabled ? theme.palette.success : theme.palette.onCoralMuted)
                            }
                            .padding(8)
                            .background(theme.palette.darkOverlay.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func queuesPanel(_ queues: [FactoryQueue]) -> some View {
        HermesSurfacePanel(title: "Milestone Lanes", subtitle: "Demand is useful only when it can be routed into repeatable parallel work.") {
            if queues.isEmpty {
                ContentUnavailableView("No queues yet", systemImage: "rectangle.3.group", description: Text("Samantha writes queue snapshots to ipop-factory.json."))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(queues) { queue in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(queue.stage.title)
                                    .font(.os1SmallCaps)
                                    .foregroundStyle(.os1OnCoralSecondary)
                                Spacer()
                                Image(systemName: queue.isBreachingSLA ? "clock.badge.exclamationmark" : "clock")
                                    .foregroundStyle(queue.isBreachingSLA ? theme.palette.warning : theme.palette.onCoralMuted)
                            }
                            Text("\(queue.count)")
                                .font(.system(.title2, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundStyle(.os1OnCoralPrimary)
                            Text(queue.name)
                                .font(.os1Body)
                                .foregroundStyle(.os1OnCoralSecondary)
                                .lineLimit(1)
                        }
                        .padding(12)
                        .background(theme.palette.darkOverlay.opacity(0.26), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func workersPanel(_ workers: [FactoryWorker]) -> some View {
        HermesSurfacePanel(title: "Workers", subtitle: "Disposable isolated sessions running in parallel.") {
            if workers.isEmpty {
                ContentUnavailableView("No worker sessions", systemImage: "person.3", description: Text("Workers appear after Samantha starts scanner, proof, fulfillment, QA, or delivery sessions."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 8) {
                    ForEach(workers.prefix(16)) { worker in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(worker.name)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.os1OnCoralPrimary)
                                    .lineLimit(1)
                                Spacer()
                                HermesBadge(text: worker.status.title, tint: tint(for: worker.status))
                            }
                            HStack(spacing: 8) {
                                HermesBadge(text: worker.role.title, tint: .accentColor)
                                if let milestoneID = worker.currentMilestoneID {
                                    Text(milestoneID)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.os1OnCoralMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func milestonesPanel(_ milestones: [FactoryMilestone]) -> some View {
        HermesSurfacePanel(title: "Milestones", subtitle: "Every job is broken into proof, execution, QA, and delivery envelopes.") {
            if milestones.isEmpty {
                ContentUnavailableView("No milestones", systemImage: "list.bullet.clipboard", description: Text("Opportunity and client-intake items become milestones here."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 8) {
                    ForEach(milestones.prefix(14)) { milestone in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(milestone.offer)
                                        .font(.os1Body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.os1OnCoralPrimary)
                                        .lineLimit(1)
                                    Text(milestone.clientSignal)
                                        .font(.os1SmallCaps)
                                        .foregroundStyle(.os1OnCoralSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(amount(milestone.budget, milestone.currency))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.os1OnCoralPrimary)
                            }

                            HStack(spacing: 8) {
                                HermesBadge(text: milestone.stage.title, tint: tint(for: milestone.stage))
                                HermesBadge(text: "QA \(milestone.qaStatus.title)", tint: tint(for: milestone.qaStatus))
                                HermesBadge(text: milestone.paymentStatus.title, tint: tint(for: milestone.paymentStatus))
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func qaPanel(_ reviews: [FactoryQAReview]) -> some View {
        HermesSurfacePanel(title: "QA Gate", subtitle: "Separate verifier agents keep parallel work from becoming parallel mess.") {
            if reviews.isEmpty {
                ContentUnavailableView("No QA reviews", systemImage: "checkmark.shield", description: Text("Verifier outputs appear here before client delivery."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(reviews.prefix(10)) { review in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(review.reviewer)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                Spacer()
                                HermesBadge(text: review.status.title, tint: tint(for: review.status))
                            }
                            Text("\(review.checksPassed)/\(review.checksTotal) checks · \(review.milestoneID)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.os1OnCoralMuted)
                                .lineLimit(1)
                            if !review.notes.isEmpty {
                                Text(review.notes)
                                    .font(.os1SmallCaps)
                                    .foregroundStyle(.os1OnCoralSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func paymentsPanel(_ payments: [FactoryPayment]) -> some View {
        HermesSurfacePanel(title: "Stripe Lane", subtitle: "Milestones should not ship blind; payment state travels with the work.") {
            if payments.isEmpty {
                ContentUnavailableView("No payment records", systemImage: "creditcard", description: Text("Stripe sessions and invoices appear here after the factory records them."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(payments.prefix(10)) { payment in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(payment.milestoneID)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.os1OnCoralPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(payment.stripeObjectID ?? payment.status.title)
                                    .font(.os1SmallCaps)
                                    .foregroundStyle(.os1OnCoralSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(amount(payment.amount, payment.currency))
                                .font(.system(.caption, design: .monospaced))
                            HermesBadge(text: payment.status.title, tint: tint(for: payment.status))
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func ledgerPanel(_ ledger: [FactoryRevenueLedgerEntry]) -> some View {
        HermesSurfacePanel(title: "Revenue Ledger", subtitle: "Projected, quoted, invoiced, pending, and received money by opportunity.") {
            if ledger.isEmpty {
                ContentUnavailableView("No ledger entries", systemImage: "dollarsign.arrow.circlepath", description: Text("Qualified jobs create ledger rows before work is promoted to milestones."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(ledger.prefix(10)) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.opportunityID ?? entry.milestoneID ?? entry.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.os1OnCoralPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entry.blockerReason ?? "Pending payment path")
                                    .font(.os1SmallCaps)
                                    .foregroundStyle(.os1OnCoralSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(amount(entry.quotedValue, entry.currency))
                                Text("net " + amount(entry.netReceived, entry.currency))
                                    .foregroundStyle(.os1OnCoralMuted)
                            }
                            .font(.system(.caption, design: .monospaced))
                            HermesBadge(text: entry.paymentStatus.title, tint: tint(for: entry.paymentStatus))
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func eventsPanel(_ events: [FactoryEvent]) -> some View {
        HermesSurfacePanel(title: "Audit Events", subtitle: "Every discovery, gate, scoring, draft, approval, and payment transition leaves evidence.") {
            if events.isEmpty {
                ContentUnavailableView("No events", systemImage: "list.bullet.rectangle", description: Text("Samantha records lead pipeline transitions here."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(events.prefix(10)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.action)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Spacer()
                                Text(event.timestamp)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.os1OnCoralMuted)
                                    .lineLimit(1)
                            }
                            Text(event.evidence.isEmpty ? event.subjectID : event.evidence)
                                .font(.os1SmallCaps)
                                .foregroundStyle(.os1OnCoralSecondary)
                                .lineLimit(2)
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func statePathPanel(_ dashboard: FactoryDashboard) -> some View {
        Text("State file: \(dashboard.statePath)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.os1OnCoralMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 2)
    }

    private var emptyPanel: some View {
        HermesSurfacePanel {
            ContentUnavailableView("Factory state unavailable", systemImage: "rectangle.3.group.bubble", description: Text("Select a Samantha host. The factory reads ~/ipop-factory.json when the parallel runtime starts writing state."))
                .frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    private func errorPanel(_ error: String) -> some View {
        Text(error)
            .font(.os1Body)
            .foregroundStyle(.os1OnCoralPrimary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metricTile(_ label: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(label))
                    .font(.os1SmallCaps)
                    .foregroundStyle(.os1OnCoralSecondary)
                Text(value)
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.os1OnCoralPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func amount(_ value: Double, _ currency: String) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(value.rounded() == value ? 0 : 2)))
    }

    private func tint(for stage: FactoryStage) -> Color {
        switch stage {
        case .demand, .proof:
            theme.palette.warning
        case .paid, .executing:
            .accentColor
        case .qa:
            theme.palette.onCoralMuted
        case .delivery:
            theme.palette.success
        case .blocked:
            theme.palette.danger
        }
    }

    private func tint(for status: FactoryWorkerStatus) -> Color {
        switch status {
        case .idle, .queued:
            theme.palette.onCoralMuted
        case .running:
            theme.palette.success
        case .waiting:
            theme.palette.warning
        case .blocked, .failed:
            theme.palette.danger
        }
    }

    private func tint(for status: FactoryQAStatus) -> Color {
        switch status {
        case .notStarted:
            theme.palette.onCoralMuted
        case .pending:
            theme.palette.warning
        case .passed:
            theme.palette.success
        case .failed, .needsHuman:
            theme.palette.danger
        }
    }

    private func tint(for status: FactoryPaymentStatus) -> Color {
        switch status {
        case .unpaid:
            theme.palette.onCoralMuted
        case .depositPaid:
            theme.palette.warning
        case .paid:
            theme.palette.success
        case .disputed, .refunded:
            theme.palette.danger
        }
    }

    private func tint(for status: RemoteJobOpportunityStatus) -> Color {
        switch status {
        case .found, .parsed, .ranked:
            theme.palette.onCoralMuted
        case .qualified, .drafted, .approvedToSubmit:
            theme.palette.warning
        case .submitted, .accepted, .inProgress, .qa:
            .accentColor
        case .delivered, .invoiced, .paid:
            theme.palette.success
        case .rejected, .closed:
            theme.palette.danger
        }
    }
}
