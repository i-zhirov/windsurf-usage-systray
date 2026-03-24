import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss

    @State private var warningThreshold: Double = 80
    @State private var criticalThreshold: Double = 90
    @State private var notificationsEnabled: Bool = true
    @State private var compactDisplay: Bool = true
    @State private var preferLiveMode: Bool = true
    @State private var showSourceInPopover: Bool = true
    @State private var showUsedInsteadOfRemaining: Bool = false
    @State private var refreshOnPopoverOpen: Bool = false
    @State private var refreshIntervalMinutes: Double = 2
    @State private var killswitchEnabled: Bool = false
    @State private var killswitchThreshold: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("Data Source") {
                    HStack {
                        Image(systemName: preferLiveMode ? "bolt.horizontal.fill" : "externaldrive.fill")
                            .foregroundColor(.green)
                        Text(preferLiveMode ? "Prefer live Windsurf language server" : "Using cached Windsurf state")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(preferLiveMode ? "Live" : "Cache")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }

                    Toggle("Prefer live Windsurf data", isOn: $preferLiveMode)
                        .onChange(of: preferLiveMode) { newValue in
                            settingsManager.setPreferLiveMode(newValue)
                        }

                    Toggle("Show source in popover", isOn: $showSourceInPopover)
                        .onChange(of: showSourceInPopover) { newValue in
                            settingsManager.setShowSourceInPopover(newValue)
                        }
                }

                Section("Menu Bar") {
                    Toggle("Show both quotas (daily • weekly)", isOn: $compactDisplay)
                        .onChange(of: compactDisplay) { newValue in
                            settingsManager.setCompactDisplay(newValue)
                        }

                    Toggle("Show used instead of remaining", isOn: $showUsedInsteadOfRemaining)
                        .onChange(of: showUsedInsteadOfRemaining) { newValue in
                            settingsManager.setShowUsedInsteadOfRemaining(newValue)
                        }

                    Toggle("Refresh on popover open", isOn: $refreshOnPopoverOpen)
                        .onChange(of: refreshOnPopoverOpen) { newValue in
                            settingsManager.setRefreshOnPopoverOpen(newValue)
                        }

                    VStack(alignment: .leading) {
                        Text("Refresh interval: \(Int(refreshIntervalMinutes)) min")
                        Slider(value: $refreshIntervalMinutes, in: 1...10, step: 1)
                            .onChange(of: refreshIntervalMinutes) { newValue in
                                settingsManager.setRefreshIntervalMinutes(Int(newValue))
                            }
                    }
                }

                Section("Notifications") {
                    Toggle("Enable quota alerts", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { newValue in
                            settingsManager.setNotificationsEnabled(newValue)
                        }

                    VStack(alignment: .leading) {
                        Text("Warning threshold: \(Int(warningThreshold))%")
                        Slider(value: $warningThreshold, in: 50...95, step: 5)
                            .onChange(of: warningThreshold) { newValue in
                                settingsManager.setWarningThreshold(newValue)
                            }
                    }

                    VStack(alignment: .leading) {
                        Text("Critical threshold: \(Int(criticalThreshold))%")
                        Slider(value: $criticalThreshold, in: 60...100, step: 5)
                            .onChange(of: criticalThreshold) { newValue in
                                settingsManager.setCriticalThreshold(newValue)
                            }
                    }
                }

                Section("Killswitch") {
                    Toggle("Enable killswitch", isOn: $killswitchEnabled)
                        .onChange(of: killswitchEnabled) { newValue in
                            settingsManager.setKillswitchEnabled(newValue)
                        }
                        .disabled(!preferLiveMode)

                    if killswitchEnabled && preferLiveMode {
                        VStack(alignment: .leading) {
                            Text("Trigger at: \(Int(killswitchThreshold))% remaining")
                            Slider(value: $killswitchThreshold, in: 0...20, step: 1)
                                .onChange(of: killswitchThreshold) { newValue in
                                    settingsManager.setKillswitchThreshold(Int(newValue))
                                }
                        }
                    }

                    Text(preferLiveMode
                        ? "Kills Windsurf AI when daily or weekly quota drops to threshold."
                        : "Killswitch requires Live mode to be enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()

            footer
        }
        .frame(width: 360, height: 480)
        .onAppear { loadSettings() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title)
                .foregroundColor(.blue)
            Text("Windsurf Quota Settings")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text(footerDescription)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Reset to Defaults") { resetToDefaults() }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func loadSettings() {
        warningThreshold = settingsManager.settings.warningThreshold
        criticalThreshold = settingsManager.settings.criticalThreshold
        notificationsEnabled = settingsManager.settings.notificationsEnabled
        compactDisplay = settingsManager.settings.compactDisplay
        preferLiveMode = settingsManager.settings.preferLiveMode
        showSourceInPopover = settingsManager.settings.showSourceInPopover
        showUsedInsteadOfRemaining = settingsManager.settings.showUsedInsteadOfRemaining
        refreshOnPopoverOpen = settingsManager.settings.refreshOnPopoverOpen
        refreshIntervalMinutes = Double(settingsManager.settings.refreshIntervalMinutes)
        killswitchEnabled = settingsManager.settings.killswitchEnabled
        killswitchThreshold = Double(settingsManager.settings.killswitchThreshold)
    }

    private func resetToDefaults() {
        settingsManager.resetToDefaults()
        loadSettings()
    }

    private var footerDescription: String {
        if preferLiveMode {
            return "Live via Windsurf language server, with cached fallback"
        }

        return "Using cached Windsurf local state"
    }
}
