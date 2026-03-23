import XCTest
@testable import ClaudeUsageSystray

final class WindsurfProtobufReaderTests: XCTestCase {

    func testDecodeUserStatusExtractsQuotaFields() throws {
        let data = protobufMessage([
            .message(13, protobufMessage([
                .message(1, protobufMessage([
                    .string(2, "Teams"),
                    .varint(35, 2)
                ])),
                .varint(14, 88),
                .varint(15, 49),
                .varint(17, 1_710_000_000),
                .varint(18, 1_710_500_000)
            ]))
        ])

        let status = try WindsurfProtobufReader().decodeUserStatus(data)

        XCTAssertEqual(status.dailyQuotaRemainingPercent, 88)
        XCTAssertEqual(status.weeklyQuotaRemainingPercent, 49)
        XCTAssertEqual(status.dailyQuotaResetAtUnix, 1_710_000_000)
        XCTAssertEqual(status.weeklyQuotaResetAtUnix, 1_710_500_000)
        XCTAssertEqual(status.planName, "Teams")
        XCTAssertEqual(status.billingStrategy, 2)
    }

    func testDecodeUserStatusRequiresQuotaFields() {
        let data = protobufMessage([
            .message(13, protobufMessage([
                .message(1, protobufMessage([
                    .string(2, "Teams")
                ]))
            ]))
        ])

        XCTAssertThrowsError(try WindsurfProtobufReader().decodeUserStatus(data)) { error in
            guard case WindsurfFetchError.invalidCachedUserStatus = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

final class WindsurfPlanStatusTests: XCTestCase {

    func testMakeSnapshotMapsFieldsForQuotaDisplay() {
        let status = WindsurfPlanStatus(
            dailyQuotaRemainingPercent: 91,
            weeklyQuotaRemainingPercent: 64,
            dailyQuotaResetAtUnix: 1_710_000_000,
            weeklyQuotaResetAtUnix: 1_710_500_000,
            planName: "Pro",
            billingStrategy: 2
        )

        let snapshot = status.makeSnapshot(
            source: .live,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            isStale: false,
            errorHint: nil
        )

        XCTAssertEqual(snapshot.dailyQuotaRemainingPercent, 91)
        XCTAssertEqual(snapshot.weeklyQuotaRemainingPercent, 64)
        XCTAssertEqual(snapshot.dailyQuotaUsedPercent, 9)
        XCTAssertEqual(snapshot.weeklyQuotaUsedPercent, 36)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.billingStrategy, "BILLING_STRATEGY_QUOTA")
        XCTAssertEqual(snapshot.source, .live)
        XCTAssertFalse(snapshot.isStale)
        XCTAssertEqual(snapshot.sourceLabelText, "Live")
    }
}

final class WindsurfProcessDiscoveryTests: XCTestCase {

    func testDiscoverSupportsAppleSiliconLanguageServerName() throws {
        let discovery = makeDiscovery(processLine: "123 /Applications/Windsurf.app/.../language_server_macos_arm --run_child")

        let result = try discovery.discover()

        XCTAssertEqual(result.processIdentifier, 123)
        XCTAssertEqual(result.rpcPort, 56429)
        XCTAssertEqual(result.csrfToken, "token-123")
    }

    func testDiscoverSupportsIntelLanguageServerName() throws {
        let discovery = makeDiscovery(processLine: "456 /Applications/Windsurf.app/.../language_server_macos_x64 --run_child")

        let result = try discovery.discover()

        XCTAssertEqual(result.processIdentifier, 456)
        XCTAssertEqual(result.rpcPort, 56429)
        XCTAssertEqual(result.csrfToken, "token-456")
    }

    func testDiscoverSupportsUnknownFutureMacSuffixByPrefix() throws {
        let discovery = makeDiscovery(processLine: "789 /Applications/Windsurf.app/.../language_server_macos_universal --run_child")

        let result = try discovery.discover()

        XCTAssertEqual(result.processIdentifier, 789)
    }

    private func makeDiscovery(processLine: String) -> WindsurfProcessDiscovery {
        WindsurfProcessDiscovery(commandRunner: { command, arguments in
            if command == "/bin/ps", arguments == ["-axo", "pid=,command="] {
                return processLine + "\n"
            }

            if command == "/bin/ps", arguments == ["eww", "-p", processIdentifier(from: processLine)] {
                return processLine + " WINDSURF_CSRF_TOKEN=token-\(processIdentifier(from: processLine)) PATH=/usr/bin\n"
            }

            if command == "/usr/sbin/lsof", arguments == ["-nP", "-a", "-p", processIdentifier(from: processLine), "-iTCP"] {
                return "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nls \(processIdentifier(from: processLine)) me 8u IPv4 0t0 TCP 127.0.0.1:56429 (LISTEN)\nls \(processIdentifier(from: processLine)) me 9u IPv4 0t0 TCP 127.0.0.1:56441 (LISTEN)\n"
            }

            XCTFail("Unexpected command: \(command) \(arguments)")
            return ""
        })
    }
}

final class UsageSnapshotFormattingTests: XCTestCase {

    func testCompactMenuBarFormattingUsesDailyAndWeeklyQuota() {
        let snapshot = UsageSnapshot(
            dailyQuotaRemainingPercent: 88,
            weeklyQuotaRemainingPercent: 49,
            dailyResetAt: Date().addingTimeInterval(-10),
            weeklyResetAt: Date().addingTimeInterval(-10),
            planName: "Teams",
            billingStrategy: "BILLING_STRATEGY_QUOTA",
            source: .cache,
            lastUpdated: Date(),
            isStale: true,
            errorHint: "Showing cached Windsurf data"
        )

        XCTAssertEqual(snapshot.compactMenuBarText, "D88 · W49")
        XCTAssertEqual(snapshot.menuBarPrimaryText, "D: 88%")
        XCTAssertEqual(snapshot.menuBarSecondaryText, "W: 49%")
        XCTAssertEqual(snapshot.displayText, "49%")
        XCTAssertEqual(snapshot.sourceLabelText, "Cached")
        XCTAssertEqual(snapshot.dailyResetIn, "now")
        XCTAssertEqual(snapshot.weeklyResetIn, "now")
        XCTAssertEqual(snapshot.errorHint, "Showing cached Windsurf data")
    }

    func testLegacyInitializerMapsUsedPercentBackToRemainingPercent() {
        let snapshot = UsageSnapshot(
            fiveHourUtilization: 12,
            sevenDayUtilization: 51,
            sevenDaySonnetUtilization: nil,
            fiveHourResetIn: nil,
            sevenDayResetIn: nil,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            weeklySessions: 0,
            weeklyMessages: 0,
            weeklyTokens: 0
        )

        XCTAssertEqual(snapshot.dailyQuotaRemainingPercent, 88)
        XCTAssertEqual(snapshot.weeklyQuotaRemainingPercent, 49)
        XCTAssertEqual(snapshot.fiveHourUtilization, 12)
        XCTAssertEqual(snapshot.sevenDayUtilization, 51)
        XCTAssertEqual(snapshot.source, .unavailable)
    }
}

final class CalculateUtilizationTests: XCTestCase {

    func testZeroTokensIsZeroPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 0, limit: 100_000), 0)
    }

    func testHalfLimitIsFiftyPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 100_000), 50)
    }

    func testExceedingLimitCapsAtHundred() {
        XCTAssertEqual(calculateUtilization(tokens: 200_000, limit: 100_000), 100)
    }

    func testExactLimitIsHundredPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 100_000, limit: 100_000), 100)
    }

    func testZeroLimitReturnsZero() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 0), 0)
    }

    func testRoundsDown() {
        XCTAssertEqual(calculateUtilization(tokens: 1, limit: 3), 33)
    }
}

final class FormatTimeRemainingTests: XCTestCase {

    func testPastDateReturnsNow() {
        let past = Date().addingTimeInterval(-60)
        XCTAssertEqual(formatTimeRemaining(until: past), "now")
    }

    func testFortyFiveMinutesRemaining() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(45 * 60), from: now), "45m")
    }

    func testTwoHoursThirtyMinutes() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(2 * 3600 + 30 * 60), from: now), "2h 30m")
    }

    func testExactlyOneHour() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(3600), from: now), "1h 0m")
    }
}

private enum ProtobufField {
    case varint(Int, UInt64)
    case string(Int, String)
    case message(Int, Data)
}

private func protobufMessage(_ fields: [ProtobufField]) -> Data {
    var data = Data()

    for field in fields {
        switch field {
        case .varint(let number, let value):
            data.append(varint(UInt64(number << 3)))
            data.append(varint(value))
        case .string(let number, let value):
            let stringData = Data(value.utf8)
            data.append(varint(UInt64((number << 3) | 2)))
            data.append(varint(UInt64(stringData.count)))
            data.append(stringData)
        case .message(let number, let nestedData):
            data.append(varint(UInt64((number << 3) | 2)))
            data.append(varint(UInt64(nestedData.count)))
            data.append(nestedData)
        }
    }

    return data
}

private func processIdentifier(from processLine: String) -> String {
    processLine.split(separator: " ").first.map(String.init) ?? "0"
}

private func varint(_ value: UInt64) -> Data {
    var remaining = value
    var bytes: [UInt8] = []

    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining > 0 {
            byte |= 0x80
        }
        bytes.append(byte)
    } while remaining > 0

    return Data(bytes)
}
