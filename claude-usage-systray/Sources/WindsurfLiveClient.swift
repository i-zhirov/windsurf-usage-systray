import Foundation

protocol WindsurfLiveFetching {
    func fetchSnapshot(lastUpdated: Date) async throws -> UsageSnapshot
}

final class WindsurfLiveClient {
    private let discovery: WindsurfProcessDiscovery
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let fileManager: FileManager
    private let bundleVersionProvider: () -> String

    init(
        discovery: WindsurfProcessDiscovery = WindsurfProcessDiscovery(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        bundleVersionProvider: (() -> String)? = nil
    ) {
        self.discovery = discovery
        self.session = session
        self.fileManager = fileManager
        self.bundleVersionProvider = bundleVersionProvider ?? Self.defaultBundleVersionProvider
    }

    func fetchSnapshot(lastUpdated: Date = Date()) async throws -> UsageSnapshot {
        let liveDiscovery = try discovery.discover()
        let apiKey = try cachedAPIKey()
        let request = try makeRequest(discovery: liveDiscovery, apiKey: apiKey)
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
            dailyQuotaResetAtUnix: planStatus.dailyQuotaResetAtUnix,
            weeklyQuotaResetAtUnix: planStatus.weeklyQuotaResetAtUnix,
            planName: planStatus.planInfo?.planName,
            billingStrategy: planStatus.planInfo?.billingStrategy
        ).makeSnapshot(
            source: .live,
            lastUpdated: lastUpdated,
            isStale: false,
            errorHint: nil
        )
    }

    private func makeRequest(discovery: WindsurfLiveDiscovery, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(discovery.rpcPort)/exa.language_server_pb.LanguageServerService/GetUserStatus") else {
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
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(discovery.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        return request
    }

    private func cachedAPIKey() throws -> String {
        let path = NSString(string: "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb").expandingTildeInPath
        guard fileManager.fileExists(atPath: path) else {
            throw WindsurfFetchError.stateDatabaseNotFound
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, "select value from ItemTable where key='windsurfAuthStatus';"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WindsurfFetchError.sqliteCommandFailed(message?.isEmpty == false ? message! : "Failed to read Windsurf auth status")
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let envelope = try? decoder.decode(WindsurfAuthStatusEnvelope.self, from: output),
              let apiKey = envelope.apiKey,
              !apiKey.isEmpty else {
            throw WindsurfFetchError.missingAuthStatus
        }

        return apiKey
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
    let dailyQuotaResetAtUnix: Int64?
    let weeklyQuotaResetAtUnix: Int64?
}

private struct LivePlanInfoPayload: Decodable {
    let planName: String?
    let billingStrategy: Int?
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
