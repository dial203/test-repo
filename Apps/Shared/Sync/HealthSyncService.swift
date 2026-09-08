import Foundation
import HealthKit
import HRVKit
import os

/// Incremental HealthKit → server sync.
///
/// The mechanism worth understanding: `HKAnchoredObjectQuery` hands back everything added
/// or deleted since an opaque `HKQueryAnchor`, so each run uploads only what is new. The
/// anchors are persisted, which is what keeps a nightly sync from re-sending a year of
/// beats. If the anchors are lost (reinstall), `/v1/sync/state` tells the device which
/// series the server already holds so the catch-up is bounded rather than total.
///
/// Deletions matter as much as additions. HealthKit reports a deleted sample exactly once,
/// via the anchored query, so a sync that ignores `HKDeletedObject` will silently keep
/// serving data a participant has removed from Health. Those go up as tombstones.
@MainActor
final class HealthSyncService {

    enum State: Equatable {
        case idle
        case notEnrolled
        case syncing(String)
        case failed(String)
        case done(uploaded: Int, duplicates: Int, at: Date)
    }

    private(set) var state: State = .idle

    private let health: HealthKitService
    private let client: SyncAPIClient
    private let log = Logger(subsystem: "app.nocturne", category: "sync")
    private let anchors = AnchorStore()

    /// Rows per request. Chosen so a batch stays well inside the server's 32 MB ceiling
    /// even for continuous chest-strap nights, where one series can hold 30,000 beats.
    private let batchSize = 40

    init(health: HealthKitService = .shared, client: SyncAPIClient) {
        self.health = health
        self.client = client
    }

    // MARK: - Entry points

    func enrol(participantCode: String, secret: String) async throws {
        let token = try await client.enrol(participantCode: participantCode, secret: secret)
        try TokenStore.save(token)
        state = .idle
    }

    var isEnrolled: Bool { TokenStore.load() != nil }

    /// Sync everything new. Safe to call repeatedly and from a background task; ingest is
    /// idempotent, so a partial run followed by a retry costs bandwidth and nothing else.
    func sync(nights: [AnalysedNight] = []) async {
        guard let token = TokenStore.load() else {
            state = .notEnrolled
            return
        }

        var uploaded = 0
        var duplicates = 0
        do {
            state = .syncing("Reading new samples")
            var pending = try await collectPending()

            // Derived summaries the app has already computed. Keyed by configuration, so
            // re-analysing under different settings uploads a new row rather than
            // silently replacing one.
            pending.nights = nights.compactMap { night in
                let hash = ConfigurationFingerprint.hash(night.configuration)
                return SyncWire.NightOut(
                    night_of: night.summary.nightOfKey,
                    config_hash: hash,
                    hrvkit_version: HRVKitVersion.current,
                    analysed_at: night.analysedAt,
                    summary: night.summary,
                    config: night.configuration
                )
            }

            guard !pending.isEmpty else {
                state = .done(uploaded: 0, duplicates: 0, at: Date())
                return
            }

            for (index, batch) in split(pending).enumerated() {
                state = .syncing("Uploading batch \(index + 1)")
                let result = try await uploadWithRetry(batch, token: token)
                uploaded += result.accepted.values.reduce(0, +)
                duplicates += result.duplicate.values.reduce(0, +)
            }

            // Anchors advance only after everything they cover has been accepted. A crash
            // mid-sync therefore re-reads and re-uploads, which the server deduplicates —
            // the safe direction to fail in.
            anchors.commitStaged()
            state = .done(uploaded: uploaded, duplicates: duplicates, at: Date())
            log.info("sync complete: \(uploaded) new, \(duplicates) already held")
        } catch {
            anchors.discardStaged()
            log.error("sync failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Collection

    private func collectPending() async throws -> SyncWire.Envelope {
        var envelope = SyncWire.Envelope(
            schema_version: SyncWire.schemaVersion,
            device: SyncWire.DeviceInfoOut(model: nil, system_version: nil, app_version: nil)
        )

        // Heartbeat series.
        let seriesResult = try await anchoredSamples(type: HealthTypes.heartbeatSeries)
        for sample in seriesResult.added.compactMap({ $0 as? HKHeartbeatSeriesSample }) {
            let ibi = try await health.beats(in: sample)
            guard ibi.beats.count >= 2 else { continue }
            envelope.series.append(SyncWire.SeriesOut(ibi))
        }
        envelope.deletions += seriesResult.deleted.map {
            SyncWire.DeletionOut(kind: "heartbeat_series", hk_uuid: $0.uuid.uuidString)
        }

        // Sleep staging.
        let sleepResult = try await anchoredSamples(type: HealthTypes.sleepAnalysis)
        for sample in sleepResult.added.compactMap({ $0 as? HKCategorySample }) {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            envelope.sleep.append(SyncWire.SleepOut(
                hk_uuid: sample.uuid.uuidString,
                stage: value.stage.rawValue,
                start: sample.startDate,
                end: sample.endDate,
                source_identifier: sample.sourceRevision.source.bundleIdentifier
            ))
        }
        envelope.deletions += sleepResult.deleted.map {
            SyncWire.DeletionOut(kind: "sleep_interval", hk_uuid: $0.uuid.uuidString)
        }

        // Context quantities.
        let contextTypes: [(HKQuantityType, String, HKUnit)] = [
            (HealthTypes.hrvSDNN, "hrv_sdnn", HealthTypes.ms),
            (HealthTypes.restingHeartRate, "resting_heart_rate", HealthTypes.bpm),
            (HealthTypes.respiratoryRate, "respiratory_rate", HealthTypes.breathsPerMinute),
        ]
        for (type, label, unit) in contextTypes {
            let result = try await anchoredSamples(type: type)
            for sample in result.added.compactMap({ $0 as? HKQuantitySample }) {
                envelope.context.append(SyncWire.ContextOut(
                    hk_uuid: sample.uuid.uuidString,
                    type: label,
                    start: sample.startDate,
                    end: sample.endDate,
                    value: sample.quantity.doubleValue(for: unit),
                    unit: unit.unitString,
                    source_identifier: sample.sourceRevision.source.bundleIdentifier
                ))
            }
            envelope.deletions += result.deleted.map {
                SyncWire.DeletionOut(kind: "context_sample", hk_uuid: $0.uuid.uuidString)
            }
        }

        return envelope
    }

    private struct AnchoredResult {
        let added: [HKSample]
        let deleted: [HKDeletedObject]
    }

    /// One anchored pass over a sample type. The new anchor is staged, not committed, so
    /// it only takes effect once the upload it covers has succeeded.
    private func anchoredSamples(type: HKSampleType) async throws -> AnchoredResult {
        let previous = anchors.anchor(for: type.identifier)
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: previous,
                limit: HKObjectQueryNoLimit
            ) { [anchors] _, added, deleted, newAnchor, error in
                guard !finished else { return }
                finished = true
                if let error {
                    continuation.resume(throwing: SyncError.transport(error.localizedDescription))
                    return
                }
                if let newAnchor {
                    anchors.stage(newAnchor, for: type.identifier)
                }
                continuation.resume(returning: AnchoredResult(
                    added: added ?? [], deleted: deleted ?? []
                ))
            }
            health.store.execute(query)
        }
    }

    // MARK: - Batching

    private func split(_ envelope: SyncWire.Envelope) -> [SyncWire.Envelope] {
        var batches: [SyncWire.Envelope] = []
        var current = SyncWire.Envelope(
            schema_version: envelope.schema_version, device: envelope.device
        )

        func flushIfFull() {
            if current.itemCount >= batchSize {
                batches.append(current)
                current = SyncWire.Envelope(
                    schema_version: envelope.schema_version, device: envelope.device
                )
            }
        }
        for item in envelope.series { current.series.append(item); flushIfFull() }
        for item in envelope.sleep { current.sleep.append(item); flushIfFull() }
        for item in envelope.context { current.context.append(item); flushIfFull() }
        for item in envelope.nights { current.nights.append(item); flushIfFull() }
        for item in envelope.deletions { current.deletions.append(item); flushIfFull() }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func uploadWithRetry(
        _ envelope: SyncWire.Envelope, token: String, attempts: Int = 4
    ) async throws -> SyncWire.IngestResult {
        var delay: UInt64 = 2_000_000_000  // 2 s, doubling
        var lastError: Error?
        for attempt in 1 ... attempts {
            do {
                return try await client.upload(envelope, token: token)
            } catch let error as SyncError {
                lastError = error
                guard error.isRetryable, attempt < attempts else { throw error }
                log.warning("upload attempt \(attempt) failed, retrying: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw lastError ?? SyncError.transport("upload failed")
    }
}

/// Where the HealthKit anchors live.
///
/// Staged separately from committed so an anchor never advances past data that failed to
/// upload — losing an anchor costs a redundant re-read, advancing one too early loses the
/// samples it skipped permanently.
final class AnchorStore {
    private let defaults = UserDefaults.standard
    private let prefix = "healthkit.anchor."
    private var staged: [String: HKQueryAnchor] = [:]

    func anchor(for identifier: String) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: prefix + identifier) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func stage(_ anchor: HKQueryAnchor, for identifier: String) {
        staged[identifier] = anchor
    }

    func commitStaged() {
        for (identifier, anchor) in staged {
            guard let data = try? NSKeyedArchiver.archivedData(
                withRootObject: anchor, requiringSecureCoding: true
            ) else { continue }
            defaults.set(data, forKey: prefix + identifier)
        }
        staged = [:]
    }

    func discardStaged() {
        staged = [:]
    }

    /// Wipe every anchor, forcing a full re-read. Use after a restore, or when the server
    /// reports it is missing data the device believed it had already sent.
    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        staged = [:]
    }
}

enum HRVKitVersion {
    static let current = "0.1.0"
}
