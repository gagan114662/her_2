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
            subtitle: "A Conductor-inspired control tower for parallel agent labor: demand queues, worker sessions, QA gates, artifacts, and Stripe-backed milestone state."
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

            statePathPanel(dashboard)
        }
    }

    private func summaryPanel(_ summary: FactorySummary) -> some View {
        HermesSurfacePanel(title: "Parallel Capacity", subtitle: "How much agent labor Samantha can keep moving at once.") {
            HStack(spacing: 12) {
                metricTile("Workers", "\(summary.activeWorkers)/\(summary.maxWorkers)", systemImage: "person.3.sequence")
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
}
