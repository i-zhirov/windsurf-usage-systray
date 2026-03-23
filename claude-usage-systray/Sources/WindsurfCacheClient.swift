import Foundation

protocol WindsurfCacheFetching {
    func fetchSnapshot(settings: AppSettings) throws -> UsageSnapshot
}

final class WindsurfCacheClient {
    private let protobufReader = WindsurfProtobufReader()
    private let stateStore: WindsurfStateStore
    private let nowProvider: () -> Date

    init(stateStore: WindsurfStateStore = .shared, nowProvider: @escaping () -> Date = Date.init) {
        self.stateStore = stateStore
        self.nowProvider = nowProvider
    }

    func fetchSnapshot(settings: AppSettings) throws -> UsageSnapshot {
        let envelope = try stateStore.readAuthStatus()

        guard let userStatusProtoBinaryBase64 = envelope.userStatusProtoBinaryBase64,
              !userStatusProtoBinaryBase64.isEmpty else {
            throw WindsurfFetchError.missingUserStatusPayload
        }

        guard let protobufData = Data(base64Encoded: userStatusProtoBinaryBase64) else {
            throw WindsurfFetchError.invalidUserStatusPayload
        }

        let planStatus = try protobufReader.decodeUserStatus(protobufData)
        let lastUpdated = try stateStore.databaseLastModified()
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
}

extension WindsurfCacheClient: WindsurfCacheFetching {}
