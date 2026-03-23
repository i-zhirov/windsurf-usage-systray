import Foundation

protocol WindsurfLiveFetching {
    func fetchSnapshot(lastUpdated: Date) async throws -> UsageSnapshot
}

final class WindsurfLiveClient {
    private let discovery: WindsurfProcessDiscovery
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let stateStore: WindsurfStateStore
    private let bundleVersionProvider: () -> String

    init(
        discovery: WindsurfProcessDiscovery = WindsurfProcessDiscovery(),
        session: URLSession = .shared,
        stateStore: WindsurfStateStore = .shared,
        bundleVersionProvider: (() -> String)? = nil
    ) {
        self.discovery = discovery
        self.session = session
        self.stateStore = stateStore
        self.bundleVersionProvider = bundleVersionProvider ?? Self.defaultBundleVersionProvider
    }

    func fetchSnapshot(lastUpdated: Date = Date()) async throws -> UsageSnapshot {
        let liveDiscovery = try discovery.discover()
        let apiKey = try cachedAPIKey()

        guard !liveDiscovery.candidateRPCPorts.isEmpty else {
            throw WindsurfFetchError.liveDiscoveryFailed("No RPC ports found")
        }

        // Try each candidate port until one succeeds
        var lastError: Error?
        for port in liveDiscovery.candidateRPCPorts {
            do {
                return try await fetchFromPort(port, discovery: liveDiscovery, apiKey: apiKey, lastUpdated: lastUpdated)
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? WindsurfFetchError.liveRequestFailed("All RPC ports failed")
    }

    private func fetchFromPort(_ port: Int, discovery: WindsurfLiveDiscovery, apiKey: String, lastUpdated: Date) async throws -> UsageSnapshot {
        let request = try makeRequest(port: port, csrfToken: discovery.csrfToken, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WindsurfFetchError.liveRequestFailed("Invalid Windsurf live response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WindsurfFetchError.liveRequestFailed(errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let payload = try decoder.decode(GetUserStatusEnvelope.self, from: data)

        guard let planStatus = payload.userStatus?.planStatus else {
            throw WindsurfFetchError.liveRequestFailed("Missing Windsurf plan status")
        }

        return WindsurfPlanStatus(
            dailyQuotaRemainingPercent: planStatus.dailyQuotaRemainingPercent,
            weeklyQuotaRemainingPercent: planStatus.weeklyQuotaRemainingPercent,
            dailyQuotaResetAtUnix: planStatus.dailyQuotaResetAtUnix?.value,
            weeklyQuotaResetAtUnix: planStatus.weeklyQuotaResetAtUnix?.value,
            planName: planStatus.planInfo?.planName,
            billingStrategy: billingStrategyCode(from: planStatus.planInfo?.billingStrategy)
        ).makeSnapshot(
            source: .live,
            lastUpdated: lastUpdated,
            isStale: false,
            errorHint: nil
        )
    }

    private func makeRequest(port: Int, csrfToken: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus") else {
            throw WindsurfFetchError.liveRequestFailed("Invalid Windsurf live URL")
        }

        let windsurfVersion = bundleVersionProvider()

        let payload = GetUserStatusRequest(
            metadata: MetadataPayload(
                ideName: "windsurf",
                ideVersion: windsurfVersion,
                ideType: "windsurf",
                extensionName: "windsurf",
                extensionVersion: windsurfVersion,
                apiKey: apiKey,
                locale: Locale.current.language.languageCode?.identifier ?? "en",
                os: "macOS",
                hardware: ProcessInfo.processInfo.machineArchitecture,
                disableTelemetry: false,
                sessionId: UUID().uuidString,
                sourceAddress: "127.0.0.1",
                userAgent: "windsurf-usage-systray",
                authSource: "CODEIUM"
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        return request
    }

    private func cachedAPIKey() throws -> String {
        try stateStore.readAPIKey()
    }

    private func errorMessage(from data: Data, statusCode: Int) -> String {
        if let connectError = try? decoder.decode(ConnectErrorPayload.self, from: data) {
            if let message = connectError.message?.nonEmpty {
                return "Windsurf live request failed (\(statusCode)): \(message)"
            }
            if let detail = connectError.details?.first?.message?.nonEmpty {
                return "Windsurf live request failed (\(statusCode)): \(detail)"
            }
        }

        if let rawMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawMessage.isEmpty {
            return "Windsurf live request failed (\(statusCode)): \(rawMessage)"
        }

        return "Windsurf live request failed (\(statusCode))"
    }

    private func billingStrategyCode(from rawValue: String?) -> Int? {
        guard let rawValue else { return nil }

        switch rawValue {
        case "BILLING_STRATEGY_CREDITS":
            return 1
        case "BILLING_STRATEGY_QUOTA":
            return 2
        default:
            return nil
        }
    }

    private static func defaultBundleVersionProvider() -> String {
        let windsurfAppPath = "/Applications/Windsurf.app"
        if let bundle = Bundle(path: windsurfAppPath),
           let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.nonEmpty {
            return version
        }

        return "1.108.2"
    }
}

extension WindsurfLiveClient: WindsurfLiveFetching {}

private struct GetUserStatusRequest: Encodable {
    let metadata: MetadataPayload
}

private struct MetadataPayload: Encodable {
    let ideName: String
    let ideVersion: String
    let ideType: String
    let extensionName: String
    let extensionVersion: String
    let apiKey: String
    let locale: String
    let os: String
    let hardware: String
    let disableTelemetry: Bool
    let sessionId: String
    let sourceAddress: String
    let userAgent: String
    let authSource: String
}

private struct GetUserStatusEnvelope: Decodable {
    let userStatus: UserStatusPayload?
}

private struct ConnectErrorPayload: Decodable {
    let message: String?
    let details: [ConnectErrorDetail]?
}

private struct ConnectErrorDetail: Decodable {
    let message: String?
}

private struct UserStatusPayload: Decodable {
    let planStatus: LivePlanStatusPayload?
}

private struct LivePlanStatusPayload: Decodable {
    let planInfo: LivePlanInfoPayload?
    let dailyQuotaRemainingPercent: Int
    let weeklyQuotaRemainingPercent: Int
    let dailyQuotaResetAtUnix: FlexibleInt64?
    let weeklyQuotaResetAtUnix: FlexibleInt64?
}

private struct LivePlanInfoPayload: Decodable {
    let planName: String?
    let billingStrategy: String?
}

private struct FlexibleInt64: Decodable {
    let value: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int64.self) {
            value = intValue
            return
        }

        if let stringValue = try? container.decode(String.self),
           let intValue = Int64(stringValue) {
            value = intValue
            return
        }

        value = nil
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
