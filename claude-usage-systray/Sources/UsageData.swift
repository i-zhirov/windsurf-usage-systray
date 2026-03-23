import Foundation

struct AppSettings: Codable {
    var warningThreshold: Double = 80.0
    var criticalThreshold: Double = 90.0
    var notificationsEnabled: Bool = true
    var compactDisplay: Bool = true
    var preferLiveMode: Bool = true
    var showSourceInPopover: Bool = true
    var cacheStaleAfterMinutes: Int = 15

    var isConfigured: Bool { true }
}

enum UsageDataSource: String, Codable {
    case live
    case cache
    case unavailable

    var displayName: String {
        switch self {
        case .live:
            return "Live"
        case .cache:
            return "Cached"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct UsageSnapshot {
    let dailyQuotaRemainingPercent: Int
    let weeklyQuotaRemainingPercent: Int
    let dailyResetAt: Date?
    let weeklyResetAt: Date?
    let planName: String?
    let billingStrategy: String?
    let source: UsageDataSource
    let lastUpdated: Date
    let isStale: Bool
    let errorHint: String?

    var dailyQuotaUsedPercent: Int { max(0, 100 - dailyQuotaRemainingPercent) }
    var weeklyQuotaUsedPercent: Int { max(0, 100 - weeklyQuotaRemainingPercent) }

    var dailyResetIn: String? { dailyResetAt.map { Self.formatTimeRemaining(until: $0) } }
    var weeklyResetIn: String? { weeklyResetAt.map { Self.formatTimeRemaining(until: $0) } }

    var displayText: String { "\(weeklyQuotaRemainingPercent)%" }
    var menuBarPrimaryText: String { "D: \(dailyQuotaRemainingPercent)%" }
    var menuBarSecondaryText: String { "W: \(weeklyQuotaRemainingPercent)%" }
    var compactMenuBarText: String { "D\(dailyQuotaRemainingPercent) · W\(weeklyQuotaRemainingPercent)" }
    var sourceLabelText: String { source.displayName }

    init(
        dailyQuotaRemainingPercent: Int,
        weeklyQuotaRemainingPercent: Int,
        dailyResetAt: Date?,
        weeklyResetAt: Date?,
        planName: String?,
        billingStrategy: String?,
        source: UsageDataSource,
        lastUpdated: Date,
        isStale: Bool,
        errorHint: String?
    ) {
        self.dailyQuotaRemainingPercent = dailyQuotaRemainingPercent
        self.weeklyQuotaRemainingPercent = weeklyQuotaRemainingPercent
        self.dailyResetAt = dailyResetAt
        self.weeklyResetAt = weeklyResetAt
        self.planName = planName
        self.billingStrategy = billingStrategy
        self.source = source
        self.lastUpdated = lastUpdated
        self.isStale = isStale
        self.errorHint = errorHint
    }

    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            dailyQuotaRemainingPercent: 100,
            weeklyQuotaRemainingPercent: 100,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            planName: nil,
            billingStrategy: nil,
            source: .unavailable,
            lastUpdated: Date(),
            isStale: false,
            errorHint: nil
        )
    }

    private static func formatTimeRemaining(until date: Date, from now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "now" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
