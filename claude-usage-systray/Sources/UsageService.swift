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
    private var fetchTask: Task<Void, Never>?
    private let liveRefreshInterval: TimeInterval = 90
    private let cacheRefreshInterval: TimeInterval = 5 * 60
    private let failureRetryInterval: TimeInterval = 60

    // Injectable for testing
    var urlSession: URLSession = .shared
    var liveClient: WindsurfLiveFetching
    var cacheClient: WindsurfCacheFetching

    private var cachedToken: String?
    private let appCacheDirectoryURL: URL
    private let appCacheSnapshotURL: URL

    #if DEBUG
    private let debugLogPath = "/tmp/windsurf-usage-debug.log"
    #endif

    init(
        liveClient: WindsurfLiveFetching = WindsurfLiveClient(),
        cacheClient: WindsurfCacheFetching = WindsurfCacheClient(),
        cacheDirectoryURL: URL? = nil
    ) {
        self.liveClient = liveClient
        self.cacheClient = cacheClient
        let appDirectory: URL
        if let cacheDirectoryURL {
            appDirectory = cacheDirectoryURL
        } else {
            let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            appDirectory = baseDirectory.appendingPathComponent("WindsurfUsageSystray", isDirectory: true)
        }
        self.appCacheDirectoryURL = appDirectory
        self.appCacheSnapshotURL = appDirectory.appendingPathComponent("last_snapshot.json")
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
        fetchTask?.cancel()
        fetchTask = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    func fetchUsage() {
        if fetchTask != nil {
            debugLog("skip fetch: already in progress")
            return
        }

        debugLog("fetch started")
        DispatchQueue.main.async { self.isLoading = true }

        fetchTask = Task {
            defer {
                Task { @MainActor in
                    self.fetchTask = nil
                }
            }

            let settings = await MainActor.run { SettingsManager.shared.settings }

            do {
                let resolution = try await resolveFetch(settings: settings)
                self.debugLog("fetch resolved: source=\(resolution.snapshot.source.rawValue) daily=\(resolution.snapshot.dailyQuotaRemainingPercent) weekly=\(resolution.snapshot.weeklyQuotaRemainingPercent)")
                if let message = resolution.errorMessage {
                    self.debugLog("fetch warning: \(message)")
                }

                await MainActor.run {
                    self.currentUsage = resolution.snapshot
                    self.error = resolution.errorMessage
                    self.isLoading = false
                    self.scheduleTimer(interval: resolution.nextInterval)
                }
                self.persistSnapshotForCache(resolution.snapshot)
            } catch {
                self.debugLog("fetch failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.scheduleTimer(interval: self.failureRetryInterval)
                    self.isLoading = false
                }
            }
        }
    }

    func resolveFetch(settings: AppSettings) async throws -> FetchResolution {
        debugLog("resolve start: preferLiveMode=\(settings.preferLiveMode)")
        if settings.preferLiveMode {
            do {
                let snapshot = try await withTimeout(seconds: 15) {
                    try await self.liveClient.fetchSnapshot(lastUpdated: Date())
                }

                debugLog("resolve live success")
                return FetchResolution(
                    snapshot: snapshot,
                    errorMessage: nil,
                    nextInterval: liveRefreshInterval
                )
            } catch {
                let liveError = error.localizedDescription
                debugLog("resolve live failed: \(liveError)")

                do {
                    let snapshot = try fetchCachedSnapshot(settings: settings)
                    debugLog("resolve cache fallback success")
                    return FetchResolution(
                        snapshot: snapshot,
                        errorMessage: "Live data unavailable, showing cached quota: \(liveError)",
                        nextInterval: cacheRefreshInterval
                    )
                } catch {
                    debugLog("resolve cache fallback failed: \(error.localizedDescription)")
                    throw NSError(
                        domain: "WindsurfUsage",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Live failed: \(liveError). Cache failed: \(error.localizedDescription)"]
                    )
                }
            }
        }

        let snapshot = try fetchCachedSnapshot(settings: settings)
        debugLog("resolve cache-only success")
        return FetchResolution(
            snapshot: snapshot,
            errorMessage: nil,
            nextInterval: cacheRefreshInterval
        )
    }

    private func fetchCachedSnapshot(settings: AppSettings) throws -> UsageSnapshot {
        if let persistedSnapshot = loadPersistedSnapshot(settings: settings) {
            debugLog("using persisted app cache snapshot")
            return persistedSnapshot
        }

        return try cacheClient.fetchSnapshot(settings: settings)
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        debugLog("timeout wrapper start: \(seconds)s")
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(
                    domain: "WindsurfUsage",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Live request timed out"]
                )
            }

            guard let first = try await group.next() else {
                throw NSError(
                    domain: "WindsurfUsage",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Live request failed"]
                )
            }

            group.cancelAll()
            debugLog("timeout wrapper completed")
            return first
        }
    }

    private func persistSnapshotForCache(_ snapshot: UsageSnapshot) {
        guard snapshot.source != .unavailable else { return }

        let persisted = PersistedSnapshot(
            dailyQuotaRemainingPercent: snapshot.dailyQuotaRemainingPercent,
            weeklyQuotaRemainingPercent: snapshot.weeklyQuotaRemainingPercent,
            dailyResetAtUnix: snapshot.dailyResetAt?.timeIntervalSince1970,
            weeklyResetAtUnix: snapshot.weeklyResetAt?.timeIntervalSince1970,
            planName: snapshot.planName,
            billingStrategy: snapshot.billingStrategy,
            lastUpdatedUnix: snapshot.lastUpdated.timeIntervalSince1970
        )

        do {
            try FileManager.default.createDirectory(at: appCacheDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: appCacheSnapshotURL, options: .atomic)
        } catch {
            debugLog("failed to persist app cache snapshot: \(error.localizedDescription)")
        }
    }

    private func loadPersistedSnapshot(settings: AppSettings) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: appCacheSnapshotURL),
              let persisted = try? JSONDecoder().decode(PersistedSnapshot.self, from: data) else {
            return nil
        }

        let lastUpdated = Date(timeIntervalSince1970: persisted.lastUpdatedUnix)
        let age = Date().timeIntervalSince(lastUpdated)
        let staleInterval = TimeInterval(settings.cacheStaleAfterMinutes * 60)
        let isStale = age > staleInterval

        return UsageSnapshot(
            dailyQuotaRemainingPercent: persisted.dailyQuotaRemainingPercent,
            weeklyQuotaRemainingPercent: persisted.weeklyQuotaRemainingPercent,
            dailyResetAt: persisted.dailyResetAtUnix.map { Date(timeIntervalSince1970: $0) },
            weeklyResetAt: persisted.weeklyResetAtUnix.map { Date(timeIntervalSince1970: $0) },
            planName: persisted.planName,
            billingStrategy: persisted.billingStrategy,
            source: .cache,
            lastUpdated: lastUpdated,
            isStale: isStale,
            errorHint: isStale ? "Showing cached Windsurf data" : nil
        )
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: debugLogPath) {
            if let fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) {
                do {
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                    try fileHandle.close()
                } catch {
                    try? fileHandle.close()
                }
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: debugLogPath), options: .atomic)
        }
        #endif
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

private struct PersistedSnapshot: Codable {
    let dailyQuotaRemainingPercent: Int
    let weeklyQuotaRemainingPercent: Int
    let dailyResetAtUnix: TimeInterval?
    let weeklyResetAtUnix: TimeInterval?
    let planName: String?
    let billingStrategy: String?
    let lastUpdatedUnix: TimeInterval
}
