import Foundation

struct WindsurfProtobufReader {
    private enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    func decodeUserStatus(_ data: Data) throws -> WindsurfPlanStatus {
        let candidateMessages = try messageFields(13, in: data)
        guard !candidateMessages.isEmpty else {
            throw WindsurfFetchError.invalidCachedUserStatus
        }

        for candidate in candidateMessages {
            if let planStatus = try decodePlanStatus(from: candidate), isPlausibleQuotaPlanStatus(planStatus) {
                return planStatus
            }
        }

        for candidate in candidateMessages {
            if let planStatus = try decodePlanStatus(from: candidate) {
                return planStatus
            }
        }

        throw WindsurfFetchError.invalidCachedUserStatus
    }

    private func decodePlanStatus(from planStatusData: Data) throws -> WindsurfPlanStatus? {
        guard let dailyQuotaRemainingPercent = try int32Field(14, in: planStatusData),
              let weeklyQuotaRemainingPercent = try int32Field(15, in: planStatusData) else {
            return nil
        }

        let dailyQuotaResetAtUnix = try int64Field(17, in: planStatusData)
        let weeklyQuotaResetAtUnix = try int64Field(18, in: planStatusData)

        let planInfoData = try messageField(1, in: planStatusData)
        let planName = try planInfoData.flatMap { data in try stringField(2, in: data) }
        let billingStrategy = try planInfoData.flatMap { data in try int32Field(35, in: data) }

        return WindsurfPlanStatus(
            dailyQuotaRemainingPercent: dailyQuotaRemainingPercent,
            weeklyQuotaRemainingPercent: weeklyQuotaRemainingPercent,
            dailyQuotaResetAtUnix: dailyQuotaResetAtUnix,
            weeklyQuotaResetAtUnix: weeklyQuotaResetAtUnix,
            planName: planName,
            billingStrategy: billingStrategy
        )
    }

    private func isPlausibleQuotaPlanStatus(_ planStatus: WindsurfPlanStatus) -> Bool {
        guard (0...100).contains(planStatus.dailyQuotaRemainingPercent),
              (0...100).contains(planStatus.weeklyQuotaRemainingPercent) else {
            return false
        }

        if let dailyReset = planStatus.dailyQuotaResetAtUnix, dailyReset < 1_500_000_000 {
            return false
        }

        if let weeklyReset = planStatus.weeklyQuotaResetAtUnix, weeklyReset < 1_500_000_000 {
            return false
        }

        return true
    }

    private func messageField(_ targetFieldNumber: Int, in data: Data) throws -> Data? {
        try messageFields(targetFieldNumber, in: data).first
    }

    private func messageFields(_ targetFieldNumber: Int, in data: Data) throws -> [Data] {
        try allFields(targetFieldNumber, expectedWireType: .lengthDelimited, in: data).map { Data($0) }
    }

    private func stringField(_ targetFieldNumber: Int, in data: Data) throws -> String? {
        guard let value = try firstField(targetFieldNumber, expectedWireType: .lengthDelimited, in: data) else {
            return nil
        }

        return String(data: value, encoding: .utf8)
    }

    private func int32Field(_ targetFieldNumber: Int, in data: Data) throws -> Int? {
        try int64Field(targetFieldNumber, in: data).map(Int.init)
    }

    private func int64Field(_ targetFieldNumber: Int, in data: Data) throws -> Int64? {
        guard let value = try firstField(targetFieldNumber, expectedWireType: .varint, in: data) else {
            return nil
        }

        return try decodeVarint(from: value)
    }

    private func firstField(_ targetFieldNumber: Int, expectedWireType: WireType, in data: Data) throws -> Data? {
        try allFields(targetFieldNumber, expectedWireType: expectedWireType, in: data).first
    }

    private func allFields(_ targetFieldNumber: Int, expectedWireType: WireType, in data: Data) throws -> [Data] {
        var offset = data.startIndex
        var results: [Data] = []

        while offset < data.endIndex {
            let key = try decodeVarint(from: data, offset: &offset)
            let fieldNumber = Int(key >> 3)

            guard let wireType = WireType(rawValue: Int(key & 0x07)) else {
                throw WindsurfFetchError.invalidCachedUserStatus
            }

            let value = try decodeFieldValue(wireType: wireType, from: data, offset: &offset)
            if fieldNumber == targetFieldNumber, wireType == expectedWireType {
                results.append(Data(value))
            }
        }

        return results
    }

    private func decodeFieldValue(wireType: WireType, from data: Data, offset: inout Data.Index) throws -> Data {
        switch wireType {
        case .varint:
            let start = offset
            _ = try decodeVarint(from: data, offset: &offset)
            return data[start..<offset]
        case .lengthDelimited:
            let length = try decodeVarint(from: data, offset: &offset)
            guard length >= 0 else {
                throw WindsurfFetchError.invalidCachedUserStatus
            }

            let end = offset + Int(length)
            guard end <= data.endIndex else {
                throw WindsurfFetchError.invalidCachedUserStatus
            }

            let value = data[offset..<end]
            offset = end
            return value
        case .fixed64:
            let end = offset + 8
            guard end <= data.endIndex else {
                throw WindsurfFetchError.invalidCachedUserStatus
            }

            let value = data[offset..<end]
            offset = end
            return value
        case .fixed32:
            let end = offset + 4
            guard end <= data.endIndex else {
                throw WindsurfFetchError.invalidCachedUserStatus
            }

            let value = data[offset..<end]
            offset = end
            return value
        }
    }

    private func decodeVarint(from data: Data) throws -> Int64 {
        var offset = data.startIndex
        return try decodeVarint(from: data, offset: &offset)
    }

    private func decodeVarint(from data: Data, offset: inout Data.Index) throws -> Int64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < data.endIndex {
            let byte = data[offset]
            data.formIndex(after: &offset)

            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return Int64(bitPattern: result)
            }

            shift += 7
            if shift > 63 {
                break
            }
        }

        throw WindsurfFetchError.invalidCachedUserStatus
    }
}
