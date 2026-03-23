import AppKit
import SwiftUI
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared
    
    private var lastWarningNotified: Int = 0
    private var lastCriticalNotified: Int = 0

    // Keep Combine subscriptions alive
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupNotifications()
        startUsagePolling()

        // Observe usage changes to keep the menu bar numbers up to date
        usageService.$currentUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.checkForNotifications()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDidUpdate),
            name: NSNotification.Name("UsageDidUpdate"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Windsurf Quota")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 240, height: 200)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                usageService: usageService,
                settingsManager: settingsManager
            )
        )
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    private func startUsagePolling() {
        if settingsManager.settings.isConfigured {
            usageService.startPolling()
        }
        
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    @objc private func settingsDidChange() {
        DispatchQueue.main.async {
            self.updateStatusItemAppearance()
        }
    }

    @objc private func usageDidUpdate() {
        DispatchQueue.main.async {
            self.updateStatusItemAppearance()
            self.checkForNotifications()
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let snapshot = usageService.currentUsage
        let weeklyRemaining = snapshot.weeklyQuotaRemainingPercent
        let weeklyUsed = snapshot.weeklyQuotaUsedPercent

        if settingsManager.settings.compactDisplay {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "D\(snapshot.dailyQuotaRemainingPercent)",
                attributes: [.font: font, .foregroundColor: quotaColor(forRemaining: snapshot.dailyQuotaRemainingPercent)]))
            str.append(NSAttributedString(string: " · ",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            str.append(NSAttributedString(string: "W\(weeklyRemaining)",
                attributes: [.font: font, .foregroundColor: quotaColor(forRemaining: weeklyRemaining)]))

            button.image = nil
            button.attributedTitle = str
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            let symbolName: String
            if weeklyUsed >= 90 { symbolName = "exclamationmark.triangle.fill" }
            else if weeklyUsed >= 75 { symbolName = "gauge.with.dots.needle.100percent" }
            else { symbolName = "gauge.with.dots.needle.33percent" }

            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Windsurf Quota")?
                .withSymbolConfiguration(config)
            button.attributedTitle = NSAttributedString(
                string: "\(weeklyRemaining)%",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: quotaColor(forRemaining: weeklyRemaining)
                ]
            )
        }
    }

    private func quotaColor(forRemaining remaining: Int) -> NSColor {
        let used = max(0, 100 - remaining)
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        if used >= criticalThreshold {
            return .systemRed
        } else if used >= warningThreshold {
            return .systemOrange
        }
        return .labelColor
    }

    private func checkForNotifications() {
        guard settingsManager.settings.notificationsEnabled else { return }
        
        let usage = usageService.currentUsage.weeklyQuotaUsedPercent
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)

        if usage >= criticalThreshold && lastCriticalNotified < criticalThreshold {
            sendNotification(
                title: "Critical: Windsurf Quota",
                body: "You've used \(usage)% of your weekly Windsurf quota.",
                isCritical: true
            )
            lastCriticalNotified = criticalThreshold
        } else if usage >= warningThreshold && lastWarningNotified < warningThreshold && usage < criticalThreshold {
            sendNotification(
                title: "Warning: Windsurf Quota",
                body: "You've used \(usage)% of your weekly Windsurf quota.",
                isCritical: false
            )
            lastWarningNotified = warningThreshold
        }
    }

    private func sendNotification(title: String, body: String, isCritical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isCritical ? .defaultCritical : .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }
}
