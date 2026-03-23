import SwiftUI

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @State private var showSettings = false
    @State private var showDashboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageHeader
            
            Divider()
                .padding(.vertical, 4)

            modelBreakdown

            Divider()
                .padding(.vertical, 4)

            actionButtons

            Divider()
                .padding(.vertical, 4)

            quitButton
        }
        .padding(.vertical, 8)
        .frame(minWidth: 200)
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsManager: settingsManager, usageService: usageService)
        }
    }

    private var usageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: usageIconName)
                    .foregroundColor(usageColor)
                Text("Daily: \(usageService.currentUsage.dailyQuotaRemainingPercent)%")
                    .fontWeight(.medium)
                Spacer()
                if let timeLeft = usageService.currentUsage.dailyResetIn {
                    Text(timeLeft)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(weeklyColor)
                Text("Weekly: \(usageService.currentUsage.weeklyQuotaRemainingPercent)%")
                    .fontWeight(.medium)
                Spacer()
                if let timeLeft = usageService.currentUsage.weeklyResetIn {
                    Text(timeLeft)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let planName = usageService.currentUsage.planName {
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundColor(.secondary)
                    Text(planName)
                        .font(.caption)
                    Spacer()
                    if settingsManager.settings.showSourceInPopover {
                        Text(usageService.currentUsage.sourceLabelText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else if settingsManager.settings.showSourceInPopover {
                HStack {
                    Image(systemName: "externaldrive")
                        .foregroundColor(.secondary)
                    Text("Source")
                        .font(.caption)
                    Spacer()
                    Text(usageService.currentUsage.sourceLabelText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let error = usageService.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if usageService.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 10)
            }
        }
        .padding(.horizontal, 12)
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Updated \(relativeUpdateText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            if usageService.currentUsage.isStale, let hint = usageService.currentUsage.errorHint {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var actionButtons: some View {
        VStack(spacing: 0) {
            Button(action: refreshUsage) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button(action: { showSettings = true }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var quitButton: some View {
        Button(action: quitApp) {
            HStack {
                Image(systemName: "power")
                Text("Quit")
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var usageIconName: String {
        let usage = usageService.currentUsage.dailyQuotaUsedPercent
        if usage >= 90 { return "exclamationmark.triangle.fill" }
        if usage >= 75 { return "gauge.with.dots.needle.100percent" }
        return "gauge.with.dots.needle.33percent"
    }

    private var usageColor: Color {
        let usage = usageService.currentUsage.dailyQuotaUsedPercent
        if usage >= 90 { return .red }
        if usage >= 70 { return .orange }
        return .primary
    }

    private var weeklyColor: Color {
        let usage = usageService.currentUsage.weeklyQuotaUsedPercent
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        if usage >= criticalThreshold { return .red }
        if usage >= warningThreshold { return .orange }
        return .primary
    }

    private var relativeUpdateText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: usageService.currentUsage.lastUpdated, relativeTo: Date())
    }

    private func refreshUsage() {
        usageService.fetchUsage()
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
