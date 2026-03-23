import Foundation

/// Centralized access to Windsurf's local state database.
/// Eliminates duplication between WindsurfLiveClient and WindsurfCacheClient.
final class WindsurfStateStore {
    static let shared = WindsurfStateStore()

    private let fileManager: FileManager
    private let databasePath: String

    init(fileManager: FileManager = .default, databasePath: String? = nil) {
        self.fileManager = fileManager
        self.databasePath = databasePath ?? NSString(
            string: "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
        ).expandingTildeInPath
    }

    /// Returns the path to the state database if it exists.
    func stateDatabasePath() throws -> String {
        guard fileManager.fileExists(atPath: databasePath) else {
            throw WindsurfFetchError.stateDatabaseNotFound
        }
        return databasePath
    }

    /// Reads a value from ItemTable by key.
    func readItemValue(forKey key: String) throws -> String? {
        let path = try stateDatabasePath()
        return try executeQuery(
            "select value from ItemTable where key='\(escapedSQLString(key))';",
            databasePath: path
        )
    }

    /// Returns the auth status envelope containing apiKey and cached user status.
    func readAuthStatus() throws -> WindsurfAuthStatusEnvelope {
        guard let json = try readItemValue(forKey: "windsurfAuthStatus") else {
            throw WindsurfFetchError.missingAuthStatus
        }

        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WindsurfAuthStatusEnvelope.self, from: data) else {
            throw WindsurfFetchError.invalidAuthStatusJSON
        }

        return envelope
    }

    /// Returns the API key from cached auth status.
    func readAPIKey() throws -> String {
        let envelope = try readAuthStatus()
        guard let apiKey = envelope.apiKey, !apiKey.isEmpty else {
            throw WindsurfFetchError.missingAuthStatus
        }
        return apiKey
    }

    /// Returns the last modification date of the state database.
    func databaseLastModified() throws -> Date {
        let path = try stateDatabasePath()
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return (attributes[.modificationDate] as? Date) ?? Date()
    }

    private func executeQuery(_ query: String, databasePath: String) throws -> String? {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath, query]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WindsurfFetchError.sqliteCommandFailed(
                message?.isEmpty == false ? message! : "Failed to read Windsurf state"
            )
        }

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private func escapedSQLString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
