import Foundation
import Security

// MARK: - OAuth Keychain

private struct KeychainCredentials: Decodable {
    let claudeAiOauth: OAuthData

    struct OAuthData: Decodable {
        let accessToken: String
        let expiresAt: Double
    }
}

func readOAuthAccessToken() throws -> String {
    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw NSError(domain: "Keychain", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "Claude Code credentials not found in Keychain. Make sure Claude Code is installed and logged in. (status: \(status))"])
    }
    let creds = try JSONDecoder().decode(KeychainCredentials.self, from: data)
    return creds.claudeAiOauth.accessToken
}

// MARK: - API Response Model

struct OAuthUsageResponse: Decodable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDaySonnet: UsagePeriod?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    struct UsagePeriod: Decodable {
        let utilization: Double
        let resetsAt: String

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var resetsAtDate: Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: resetsAt)
        }
    }
}

// MARK: - Utilization helpers (pure, testable)

/// Returns utilization percentage (0–100) given token count and limit.
func calculateUtilization(tokens: Int, limit: Int) -> Int {
    guard limit > 0 else { return 0 }
    return min(100, tokens * 100 / limit)
}

/// Formats a future date as a human-readable countdown string.
func formatTimeRemaining(until date: Date, from now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "now" }
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

// MARK: - UsageService

final class UsageService: ObservableObject {
    static let shared = UsageService()

    struct FetchResolution {
        let snapshot: UsageSnapshot
        let errorMessage: String?
        let nextInterval: TimeInterval
    }

    @Published private(set) var currentUsage: UsageSnapshot = .placeholder
    @Published private(set) var error: String?
    @Published private(set) var isLoading: Bool = false

    private var refreshTimer: Timer?
    private let liveRefreshInterval: TimeInterval = 90
    private let cacheRefreshInterval: TimeInterval = 5 * 60
    private let failureRetryInterval: TimeInterval = 60

    // Injectable for testing
    var urlSession: URLSession = .shared
    var liveClient: WindsurfLiveFetching
    var cacheClient: WindsurfCacheFetching

    private var cachedToken: String?

    init(
        liveClient: WindsurfLiveFetching = WindsurfLiveClient(),
        cacheClient: WindsurfCacheFetching = WindsurfCacheClient()
    ) {
        self.liveClient = liveClient
        self.cacheClient = cacheClient
    }

    private func accessToken() throws -> String {
        if let token = cachedToken { return token }
        let token = try readOAuthAccessToken()
        cachedToken = token
        return token
    }

    func startPolling() {
        fetchUsage()
        scheduleTimer(interval: cacheRefreshInterval)
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    func fetchUsage() {
        DispatchQueue.main.async { self.isLoading = true }

        Task {
            let settings = await MainActor.run { SettingsManager.shared.settings }

            do {
                let resolution = try await resolveFetch(settings: settings)

                await MainActor.run {
                    self.currentUsage = resolution.snapshot
                    self.error = resolution.errorMessage
                    self.isLoading = false
                    self.scheduleTimer(interval: resolution.nextInterval)
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.scheduleTimer(interval: self.failureRetryInterval)
                    self.isLoading = false
                }
            }
        }
    }

    func resolveFetch(settings: AppSettings) async throws -> FetchResolution {
        if settings.preferLiveMode {
            do {
                let snapshot = try await liveClient.fetchSnapshot(lastUpdated: Date())
                return FetchResolution(
                    snapshot: snapshot,
                    errorMessage: nil,
                    nextInterval: liveRefreshInterval
                )
            } catch {
                let liveError = error.localizedDescription

                do {
                    let snapshot = try cacheClient.fetchSnapshot(settings: settings)
                    return FetchResolution(
                        snapshot: snapshot,
                        errorMessage: "Live data unavailable, showing cached quota: \(liveError)",
                        nextInterval: cacheRefreshInterval
                    )
                } catch {
                    throw NSError(
                        domain: "WindsurfUsage",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Live failed: \(liveError). Cache failed: \(error.localizedDescription)"]
                    )
                }
            }
        }

        let snapshot = try cacheClient.fetchSnapshot(settings: settings)
        return FetchResolution(
            snapshot: snapshot,
            errorMessage: nil,
            nextInterval: cacheRefreshInterval
        )
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        print("[UsageService] GET /api/oauth/usage")

        let (data, response) = try await urlSession.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? "<binary>"

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("[UsageService] HTTP \(http.statusCode) — \(body.prefix(300))")

        guard http.statusCode == 200 else {
            throw NSError(domain: "OAuthUsage", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
