import Foundation
import HRVKit

/// Wire format, version 1. Mirrors `server/nocturne_sync/schemas.py`.
/// Change one and you must change both, and bump `SyncWire.schemaVersion`.
enum SyncWire {
    static let schemaVersion = 1

    /// Every timestamp goes out with an explicit offset. A naive timestamp in sleep data
    /// is an unrecoverable error: afterwards you cannot tell whether 02:00 meant local or
    /// UTC, and night attribution turns on exactly that. The server rejects them.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return decoder
    }()

    struct BeatOut: Codable {
        let offset: TimeInterval
        let precededByGap: Bool
    }

    struct SeriesOut: Codable {
        let hk_uuid: String
        let start: Date
        let beats: [BeatOut]
        let source_identifier: String?
        let device_name: String?

        init(_ series: IBISeries) {
            hk_uuid = series.id.uuidString
            start = series.start
            beats = series.beats.map { BeatOut(offset: $0.offset, precededByGap: $0.precededByGap) }
            source_identifier = series.sourceIdentifier
            device_name = series.deviceName
        }
    }

    struct SleepOut: Codable {
        let hk_uuid: String
        let stage: String
        let start: Date
        let end: Date
        let source_identifier: String?
    }

    struct ContextOut: Codable {
        let hk_uuid: String
        let type: String
        let start: Date
        let end: Date
        let value: Double
        let unit: String
        let source_identifier: String?
    }

    struct NightOut: Codable {
        let night_of: String
        let config_hash: String
        let hrvkit_version: String
        let analysed_at: Date
        /// HealthKit source bundle identifiers that contributed beats to this night.
        ///
        /// Reported from the device because it is the only place that can: night
        /// boundaries are computed in the participant's local time, and the server does
        /// not store their timezone, so it cannot re-derive which samples fell inside a
        /// night. Without this a consumer cannot tell a watch-derived RMSSD from one
        /// backed by a chest strap written into HealthKit by this same app.
        let sources: [String]
        let summary: NightSummary
        let config: NightAnalysisConfiguration
    }

    struct DeletionOut: Codable {
        let kind: String
        let hk_uuid: String
    }

    struct DeviceInfoOut: Codable {
        let model: String?
        let system_version: String?
        let app_version: String?
    }

    struct Envelope: Codable {
        let schema_version: Int
        let device: DeviceInfoOut
        var series: [SeriesOut] = []
        var sleep: [SleepOut] = []
        var context: [ContextOut] = []
        var nights: [NightOut] = []
        var deletions: [DeletionOut] = []

        var isEmpty: Bool {
            series.isEmpty && sleep.isEmpty && context.isEmpty
                && nights.isEmpty && deletions.isEmpty
        }

        /// Rough row count, used to decide when a batch is large enough to send.
        var itemCount: Int {
            series.count + sleep.count + context.count + nights.count + deletions.count
        }
    }

    struct IngestResult: Codable {
        let accepted: [String: Int]
        let duplicate: [String: Int]
        let tombstoned: Int
    }

    struct EnrolRequest: Codable {
        let participant_code: String
        let enrolment_secret: String
        let device: DeviceInfoOut
    }

    struct EnrolResponse: Codable {
        let device_token: String
        let participant_code: String
    }

    struct SyncStateResponse: Codable {
        let participant_code: String
        let series_count: Int
        let latest_series_start: Date?
        let night_count: Int
        let latest_night_of: String?
        let known_series_uuids: [String]
    }
}

/// The night label a summary belongs to, formatted the way the server stores it.
/// Local calendar on purpose: a night is a local-time concept and forcing it to UTC would
/// shift labels for anyone west of Greenwich.
extension NightSummary {
    var nightOfKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: nightOf)
    }
}
