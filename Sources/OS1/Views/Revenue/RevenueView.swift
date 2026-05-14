import SwiftUI

struct RevenueView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        HermesPageContainer(width: .analytics) {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let error = appState.revenueError {
                    errorPanel(error)
                }

                if appState.isLoadingRevenue, appState.revenueDashboard == nil {
                    HermesSurfacePanel {
                        HermesLoadingState(label: "Loading revenue state...", minHeight: 320)
                    }
                } else if let dashboard = appState.revenueDashboard {
                    dashboardContent(dashboard)
                } else {
                    emptyPanel
                }
            }
        }
        .task(id: appState.activeConnectionID) {
            await appState.loadRevenueDashboard()
        }
    }

    private var header: some View {
        HermesPageHeader(
            title: "Revenue",
            subtitle: "Track autonomous revenue workflows, setup health, live earnings, and agent-managed fleet state from the active Samantha host."
        ) {
            HStack(spacing: 8) {
                Button {
                    Task { await appState.bootstrapRevenueAutomation() }
                } label: {
                    Label("Bootstrap", systemImage: "bolt.badge.checkmark")
                }
                .buttonStyle(.os1Secondary)
                .disabled(appState.activeConnection == nil || appState.isBootstrappingRevenue)

                HermesRefreshButton(isRefreshing: appState.isRefreshingRevenue) {
                    Task { await appState.refreshRevenueDashboard(manual: true) }
                }
                .disabled(appState.activeConnection == nil || appState.isBootstrappingRevenue)
            }
        }
    }

    private func dashboardContent(_ dashboard: RevenueDashboard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            totalsPanel(dashboard.totals)
            setupPanel(dashboard.setup, logPath: dashboard.logPath)

            HStack(alignment: .top, spacing: 16) {
                workflowsPanel(dashboard.workflows)
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
                fleetPanel(dashboard.fleet)
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .top)
            }

            HStack(alignment: .top, spacing: 16) {
                eventsPanel(dashboard.events)
                    .frame(minWidth: 520, maxWidth: .infinity, alignment: .top)
                reviewsPanel(dashboard.reviews)
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func totalsPanel(_ totals: RevenueTotals) -> some View {
        HermesSurfacePanel(title: "Earnings", subtitle: "Payments and settled campaign rewards recorded in revenue-log.json.") {
            HStack(spacing: 12) {
                metricTile("Today", amount(totals.today, totals.currency), systemImage: "sun.max")
                metricTile("This Week", amount(totals.week, totals.currency), systemImage: "calendar")
                metricTile("This Month", amount(totals.month, totals.currency), systemImage: "calendar.badge.clock")
                metricTile("All Time", amount(totals.allTime, totals.currency), systemImage: "chart.line.uptrend.xyaxis")
            }
        }
    }

    private func setupPanel(_ setup: RevenueSetupStatus, logPath: String) -> some View {
        HermesSurfacePanel(title: "Automation Health", subtitle: logPath) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                setupItem("Mission brief", setup.missionExists)
                setupItem("Revenue log", setup.revenueLogExists)
                setupItem("Weekly reviewer", setup.reviewAgentExists)
                setupItem("n8n healthz", setup.n8nHealthy)
                setupItem("n8n active", setup.n8nServiceActive)
                setupItem("n8n enabled", setup.n8nServiceEnabled)
                setupItem("Cloudflare tunnel", setup.cloudflaredEnabled)
                setupItem("AiToEarn key", setup.aitoearnConfigured)
                setupItem("Social account", setup.socialAccountsConnected)
            }

            if !setup.cronEntries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("Installed crons"))
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                    ForEach(setup.cronEntries, id: \.self) { entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.os1OnCoralPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func workflowsPanel(_ workflows: [RevenueWorkflowSummary]) -> some View {
        HermesSurfacePanel(title: "Workflows", subtitle: "Per-workflow earnings and verification links.") {
            if workflows.isEmpty {
                ContentUnavailableView("No workflows yet", systemImage: "wand.and.stars", description: Text("Bootstrap the revenue loop or run a workflow to populate this table."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(workflows) { workflow in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workflow.name)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.os1OnCoralPrimary)
                                Text(workflow.status.capitalized)
                                    .font(.os1SmallCaps)
                                    .foregroundStyle(.os1OnCoralSecondary)
                            }
                            Spacer()
                            Text(amount(workflow.revenue, workflow.currency))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.os1OnCoralPrimary)
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func fleetPanel(_ fleet: [RevenueFleetComputer]) -> some View {
        HermesSurfacePanel(title: "Fleet", subtitle: "Agent-managed computers and their revenue contribution.") {
            if fleet.isEmpty {
                ContentUnavailableView("No managed VMs", systemImage: "server.rack", description: Text("Fleet entries appear after the agent creates purpose-specific computers."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(fleet) { computer in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(computer.name)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                Spacer()
                                HermesBadge(text: computer.status.capitalized, tint: computer.failureCount >= 3 ? .orange : .green)
                            }
                            Text(computer.purpose)
                                .font(.os1SmallCaps)
                                .foregroundStyle(.os1OnCoralSecondary)
                            HStack {
                                Text(computer.uptime)
                                Spacer()
                                Text(amount(computer.revenue, computer.currency))
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.os1OnCoralMuted)
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func eventsPanel(_ events: [RevenueEvent]) -> some View {
        HermesSurfacePanel(title: "Latest Events", subtitle: "Live actions, post URLs, flow IDs, and errors from the shared log.") {
            if events.isEmpty {
                ContentUnavailableView("No events logged", systemImage: "list.bullet.rectangle", description: Text("The agent writes events here after each run."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 8) {
                    ForEach(events.prefix(12)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(event.error == nil ? theme.palette.success : theme.palette.warning)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.workflow)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                Text(event.action ?? event.platform ?? event.flowID ?? "Logged event")
                                    .font(.os1SmallCaps)
                                    .foregroundStyle(.os1OnCoralSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(amount(event.amount, event.currency))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func reviewsPanel(_ reviews: [RevenueReview]) -> some View {
        HermesSurfacePanel(title: "Weekly Reviews", subtitle: "Keep, kill, improve, and A/B-test decisions.") {
            if reviews.isEmpty {
                ContentUnavailableView("No reviews yet", systemImage: "arrow.triangle.2.circlepath", description: Text("The Sunday review cron appends decisions here."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 8) {
                    ForEach(reviews.prefix(8)) { review in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(review.workflow)
                                    .font(.os1Body)
                                    .fontWeight(.semibold)
                                Spacer()
                                HermesBadge(text: review.verdict.capitalized, tint: .accentColor)
                            }
                            Text(review.actionTaken)
                                .font(.os1SmallCaps)
                                .foregroundStyle(.os1OnCoralSecondary)
                                .lineLimit(3)
                        }
                        .padding(10)
                        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var emptyPanel: some View {
        HermesSurfacePanel {
            ContentUnavailableView("Revenue state unavailable", systemImage: "dollarsign.arrow.circlepath", description: Text("Select a connected host or bootstrap the revenue automation."))
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
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.darkOverlay.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func setupItem(_ title: String, _ isReady: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isReady ? theme.palette.success : theme.palette.onCoralMuted)
            Text(L10n.string(title))
                .font(.os1Body)
                .foregroundStyle(.os1OnCoralPrimary)
            Spacer()
        }
        .padding(10)
        .background(theme.palette.darkOverlay.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
    }

    private func amount(_ value: Double, _ currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }
}
