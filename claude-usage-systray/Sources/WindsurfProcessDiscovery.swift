import Foundation

final class WindsurfProcessDiscovery {
    typealias CommandRunner = (String, [String]) throws -> String

    private struct ProcessContext {
        let processIdentifier: Int32
        let command: String
    }

    private let supportedLanguageServerNames = [
        "language_server_macos_arm",
        "language_server_macos_x64"
    ]

    private let processInfo: ProcessInfo
    private let commandRunner: CommandRunner

    init(processInfo: ProcessInfo = .processInfo, commandRunner: CommandRunner? = nil) {
        self.processInfo = processInfo
        self.commandRunner = commandRunner ?? Self.defaultRunCommand(processInfo: processInfo)
    }

    func discover() throws -> WindsurfLiveDiscovery {
        let processContext = try languageServerProcessContext()
        let environment = try processEnvironment(processIdentifier: processContext.processIdentifier)
        let extensionServerPort = extensionServerPort(from: processContext.command)
        let rpcPort = try localRPCPort(
            processIdentifier: processContext.processIdentifier,
            extensionServerPort: extensionServerPort
        )

        guard let csrfToken = environment["WINDSURF_CSRF_TOKEN"], !csrfToken.isEmpty else {
            throw WindsurfFetchError.liveDiscoveryFailed("Missing WINDSURF_CSRF_TOKEN")
        }

        return WindsurfLiveDiscovery(
            processIdentifier: processContext.processIdentifier,
            rpcPort: rpcPort,
            csrfToken: csrfToken
        )
    }

    private func languageServerProcessContext() throws -> ProcessContext {
        let output = try commandRunner("/bin/ps", ["-axo", "pid=,command="])
        var candidates: [ProcessContext] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard isSupportedLanguageServerProcess(trimmed) else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let pidString = parts.first, let pid = Int32(pidString) else { continue }
            candidates.append(ProcessContext(processIdentifier: pid, command: trimmed))
        }

        if let bestCandidate = candidates.max(by: { $0.processIdentifier < $1.processIdentifier }) {
            return bestCandidate
        }

        throw WindsurfFetchError.liveDiscoveryFailed("Windsurf language server is not running")
    }

    private func isSupportedLanguageServerProcess(_ command: String) -> Bool {
        supportedLanguageServerNames.contains { command.contains($0) }
            || command.contains("language_server_macos_")
    }

    private func processEnvironment(processIdentifier: Int32) throws -> [String: String] {
        let output = try commandRunner("/bin/ps", ["eww", "-p", String(processIdentifier)])
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

    private func localRPCPort(processIdentifier: Int32, extensionServerPort: Int?) throws -> Int {
        let output = try commandRunner("/usr/sbin/lsof", ["-nP", "-a", "-p", String(processIdentifier), "-iTCP"])

        var listenPorts: [Int] = []
        for line in output.split(separator: "\n") {
            let value = String(line)
            guard value.contains("127.0.0.1:"), value.contains("(LISTEN)") else { continue }
            guard let port = parsePort(from: value) else { continue }
            listenPorts.append(port)
        }

        guard !listenPorts.isEmpty else {
            throw WindsurfFetchError.liveDiscoveryFailed("Unable to find Windsurf local RPC port")
        }

        let candidatePorts = listenPorts
            .filter { port in
                guard let extensionServerPort else { return true }
                return port != extensionServerPort
            }
            .sorted()

        if let extensionServerPort,
           let preferredPort = candidatePorts.first(where: { $0 > extensionServerPort }) {
            return preferredPort
        }

        if let preferredPort = candidatePorts.first {
            return preferredPort
        }

        if let fallbackPort = listenPorts.sorted().first {
            return fallbackPort
        }

        throw WindsurfFetchError.liveDiscoveryFailed("Unable to determine Windsurf local RPC port")
    }

    private func parsePort(from line: String) -> Int? {
        guard let localhostRange = line.range(of: "127.0.0.1:") else { return nil }
        let suffix = line[localhostRange.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private func extensionServerPort(from command: String) -> Int? {
        let components = command.split(separator: " ")
        guard let index = components.firstIndex(of: "--extension_server_port"), index < components.index(before: components.endIndex) else {
            return nil
        }

        return Int(components[components.index(after: index)])
    }

    private static func defaultRunCommand(processInfo: ProcessInfo) -> CommandRunner {
        return { executablePath, arguments in
            try Self.runCommand(executablePath, arguments: arguments, processInfo: processInfo)
        }
    }

    private static func runCommand(_ executablePath: String, arguments: [String], processInfo: ProcessInfo) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ["PATH": processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]

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
