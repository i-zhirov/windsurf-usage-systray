import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }

    private let defaults = UserDefaults.standard
    private let settingsKey = "WindsurfUsageSettings"
    private let legacySettingsKey = "ClaudeUsageSettings"

    private init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else if let data = defaults.data(forKey: legacySettingsKey),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    func setWarningThreshold(_ value: Double) { settings.warningThreshold = value }
    func setCriticalThreshold(_ value: Double) { settings.criticalThreshold = value }
    func setNotificationsEnabled(_ enabled: Bool) { settings.notificationsEnabled = enabled }
    func setCompactDisplay(_ enabled: Bool) { settings.compactDisplay = enabled }
    func setPreferLiveMode(_ enabled: Bool) { settings.preferLiveMode = enabled }
    func setShowSourceInPopover(_ enabled: Bool) { settings.showSourceInPopover = enabled }
    func setCacheStaleAfterMinutes(_ minutes: Int) { settings.cacheStaleAfterMinutes = minutes }
    func setShowUsedInsteadOfRemaining(_ enabled: Bool) { settings.showUsedInsteadOfRemaining = enabled }
    func setRefreshOnPopoverOpen(_ enabled: Bool) { settings.refreshOnPopoverOpen = enabled }
    func setRefreshIntervalMinutes(_ minutes: Int) { settings.refreshIntervalMinutes = minutes }
    func resetToDefaults() { settings = AppSettings() }
}
