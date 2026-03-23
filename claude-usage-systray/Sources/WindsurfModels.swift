import Foundation

struct WindsurfPlanStatus {
    let dailyQuotaRemainingPercent: Int
    let weeklyQuotaRemainingPercent: Int
    let dailyQuotaResetAtUnix: Int64?
    let weeklyQuotaResetAtUnix: Int64?
    let planName: String?
    let billingStrategy: Int?

    func makeSnapshot(source: UsageDataSource, lastUpdated: Date, isStale: Bool, errorHint: String?) -> UsageSnapshot {
        UsageSnapshot(
            dailyQuotaRemainingPercent: dailyQuotaRemainingPercent,
            weeklyQuotaRemainingPercent: weeklyQuotaRemainingPercent,
            dailyResetAt: dailyQuotaResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            weeklyResetAt: weeklyQuotaResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            planName: planName,
            billingStrategy: billingStrategyName,
            source: source,
            lastUpdated: lastUpdated,
            isStale: isStale,
            errorHint: errorHint
        )
    }

    private var billingStrategyName: String? {
        guard let billingStrategy else { return nil }

        switch billingStrategy {
        case 1:
            return "BILLING_STRATEGY_CREDITS"
        case 2:
            return "BILLING_STRATEGY_QUOTA"
        default:
            return "BILLING_STRATEGY_\(billingStrategy)"
        }
    }
}

struct WindsurfLiveDiscovery {
    let processIdentifier: Int32
    let rpcPort: Int
    let csrfToken: String
}

struct WindsurfAuthStatusEnvelope: Decodable {
    let apiKey: String?
    let userStatusProtoBinaryBase64: String?
}

enum WindsurfFetchError: LocalizedError {
    case stateDatabaseNotFound
    case sqliteCommandFailed(String)
    case missingAuthStatus
    case invalidAuthStatusJSON
    case missingUserStatusPayload
    case invalidUserStatusPayload
    case invalidCachedUserStatus
    case liveDiscoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .stateDatabaseNotFound:
            return "Windsurf state database not found"
        case .sqliteCommandFailed(let message):
            return message
        case .missingAuthStatus:
            return "Missing Windsurf auth status"
        case .invalidAuthStatusJSON:
            return "Invalid Windsurf auth status JSON"
        case .missingUserStatusPayload:
            return "Missing cached Windsurf user status"
        case .invalidUserStatusPayload:
            return "Invalid cached Windsurf user status payload"
        case .invalidCachedUserStatus:
            return "Unable to decode cached Windsurf quota"
        case .liveDiscoveryFailed(let message):
            return message
        }
    }
}
