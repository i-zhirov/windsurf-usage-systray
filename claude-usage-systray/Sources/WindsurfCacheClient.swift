import Foundation

protocol WindsurfCacheFetching {
    func fetchSnapshot(settings: AppSettings) throws -> UsageSnapshot
}

final class WindsurfCacheClient {
    private let decoder = JSONDecoder()
    private let protobufReader = WindsurfProtobufReader()
    private let fileManager: FileManager
    private let nowProvider: () -> Date

    init(fileManager: FileManager = .default, nowProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    func fetchSnapshot(settings: AppSettings) throws -> UsageSnapshot {
        let databasePath = try stateDatabasePath()
        let authStatusJSON = try readItemValue(forKey: "windsurfAuthStatus", databasePath: databasePath)

        guard let authStatusJSON else {
            throw WindsurfFetchError.missingAuthStatus
        }

        guard let authStatusData = authStatusJSON.data(using: .utf8),
              let envelope = try? decoder.decode(WindsurfAuthStatusEnvelope.self, from: authStatusData) else {
            throw WindsurfFetchError.invalidAuthStatusJSON
        }

        guard let userStatusProtoBinaryBase64 = envelope.userStatusProtoBinaryBase64, !userStatusProtoBinaryBase64.isEmpty else {
            throw WindsurfFetchError.missingUserStatusPayload
        }

        guard let protobufData = Data(base64Encoded: userStatusProtoBinaryBase64) else {
            throw WindsurfFetchError.invalidUserStatusPayload
        }

        let planStatus = try protobufReader.decodeUserStatus(protobufData)
        let lastUpdated = try databaseLastModified(at: databasePath)
        let age = nowProvider().timeIntervalSince(lastUpdated)
        let staleInterval = TimeInterval(settings.cacheStaleAfterMinutes * 60)
        let isStale = age > staleInterval

        return planStatus.makeSnapshot(
            source: .cache,
            lastUpdated: lastUpdated,
            isStale: isStale,
            errorHint: isStale ? "Showing cached Windsurf data" : nil
        )
    }

    private func stateDatabasePath() throws -> String {
        let path = NSString(string: "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb").expandingTildeInPath
        guard fileManager.fileExists(atPath: path) else {
            throw WindsurfFetchError.stateDatabaseNotFound
        }

        return path
    }

    private func databaseLastModified(at path: String) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return (attributes[.modificationDate] as? Date) ?? nowProvider()
    }

    private func readItemValue(forKey key: String, databasePath: String) throws -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath, "select value from ItemTable where key='\(escapedSQLString(key))';"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WindsurfFetchError.sqliteCommandFailed(message?.isEmpty == false ? message! : "Failed to read Windsurf cached state")
        }

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private func escapedSQLString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

extension WindsurfCacheClient: WindsurfCacheFetching {}
