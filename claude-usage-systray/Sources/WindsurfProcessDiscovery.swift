import Foundation

final class WindsurfProcessDiscovery {
    private let supportedLanguageServerNames = [
        "language_server_macos_arm",
        "language_server_macos_x64"
    ]

    private let processInfo: ProcessInfo

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    func discover() throws -> WindsurfLiveDiscovery {
        let processIdentifier = try languageServerProcessIdentifier()
        let environment = try processEnvironment(processIdentifier: processIdentifier)
        let rpcPort = try localRPCPort(processIdentifier: processIdentifier)

        guard let csrfToken = environment["WINDSURF_CSRF_TOKEN"], !csrfToken.isEmpty else {
            throw WindsurfFetchError.liveDiscoveryFailed("Missing WINDSURF_CSRF_TOKEN")
        }

        return WindsurfLiveDiscovery(
            processIdentifier: processIdentifier,
            rpcPort: rpcPort,
            csrfToken: csrfToken
        )
    }

    private func languageServerProcessIdentifier() throws -> Int32 {
        let output = try runCommand("/bin/ps", arguments: ["-axo", "pid=,command="])

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard isSupportedLanguageServerProcess(trimmed) else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let pidString = parts.first, let pid = Int32(pidString) else { continue }
            return pid
        }

        throw WindsurfFetchError.liveDiscoveryFailed("Windsurf language server is not running")
    }

    private func isSupportedLanguageServerProcess(_ command: String) -> Bool {
        supportedLanguageServerNames.contains { command.contains($0) }
            || command.contains("language_server_macos_")
    }

    private func processEnvironment(processIdentifier: Int32) throws -> [String: String] {
        let output = try runCommand("/bin/ps", arguments: ["eww", "-p", String(processIdentifier)])
        guard let commandLine = output.split(separator: "\n").last else {
            throw WindsurfFetchError.liveDiscoveryFailed("Unable to inspect Windsurf language server environment")
        }

        var environment: [String: String] = [:]
        for token in commandLine.split(separator: " ") {
            guard let separatorIndex = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separatorIndex])
            let value = String(token[token.index(after: separatorIndex)...])
            environment[key] = value
        }

        return environment
    }

    private func localRPCPort(processIdentifier: Int32) throws -> Int {
        let output = try runCommand("/usr/sbin/lsof", arguments: ["-nP", "-a", "-p", String(processIdentifier), "-iTCP"])

        var listenPorts: [Int] = []
        for line in output.split(separator: "\n") {
            let value = String(line)
            guard value.contains("127.0.0.1:"), value.contains("(LISTEN)") else { continue }
            guard let port = parsePort(from: value) else { continue }
            listenPorts.append(port)
        }

        guard let rpcPort = listenPorts.min() else {
            throw WindsurfFetchError.liveDiscoveryFailed("Unable to find Windsurf local RPC port")
        }

        return rpcPort
    }

    private func parsePort(from line: String) -> Int? {
        guard let localhostRange = line.range(of: "127.0.0.1:") else { return nil }
        let suffix = line[localhostRange.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private func runCommand(_ executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = [
            "PATH": processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WindsurfFetchError.liveDiscoveryFailed(message?.isEmpty == false ? message! : "Command failed: \(executablePath)")
        }

        return String(decoding: stdoutData, as: UTF8.self)
    }
}
