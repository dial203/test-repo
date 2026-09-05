import Foundation
import HealthKit
import HRVKit
import os

enum HealthKitError: LocalizedError {
    case unavailable
    case notAuthorized(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this device."
        case let .notAuthorized(what):
            return "Health access for \(what) has not been granted. Enable it in Settings › Health › Data Access & Devices."
        case let .queryFailed(message):
            return "Health query failed: \(message)"
        }
    }
}

/// Thin, testable wrapper over `HKHealthStore`.
///
/// Everything here is read-only apart from the heartbeat series written by the external
/// sensor recorder. All queries are date-bounded and none of them run without an explicit
/// caller — nothing is fetched speculatively.
@MainActor
final class HealthKitService {

    static let shared = HealthKitService()

    let store = HKHealthStore()
    private let log = Logger(subsystem: "app.nocturne", category: "healthkit")

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.unavailable }
        try await store.requestAuthorization(toShare: HealthTypes.share, read: HealthTypes.read)
    }

    /// HealthKit deliberately never reveals read authorization, so the only honest check
    /// is whether a bounded query returns anything. `nil` means "cannot tell yet".
    func hasAnyHeartbeatData(since: Date) async -> Bool? {
        do {
            let samples = try await heartbeatSeriesSamples(from: since, to: Date())
            return !samples.isEmpty
        } catch {
            log.error("heartbeat availability probe failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Heartbeat series

    func heartbeatSeriesSamples(from start: Date, to end: Date) async throws -> [HKHeartbeatSeriesSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: [.strictStartDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HealthTypes.heartbeatSeries,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (samples as? [HKHeartbeatSeriesSample]) ?? [])
            }
            store.execute(query)
        }
    }

    /// Pull the individual beats out of one series sample.
    ///
    /// `precededByGap` is carried through verbatim: it marks a beat the sensor could not
    /// connect to the previous one, and the interval ending at such a beat must never be
    /// used as an NN interval.
    func beats(in sample: HKHeartbeatSeriesSample) async throws -> IBISeries {
        try await withCheckedThrowingContinuation { continuation in
            var beats: [Beat] = []
            var finished = false
            let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceStart, precededByGap, done, error in
                if let error {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                    return
                }
                beats.append(Beat(offset: timeSinceStart, precededByGap: precededByGap))
                if done {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: IBISeries(
                        id: sample.uuid,
                        start: sample.startDate,
                        beats: beats,
                        sourceIdentifier: sample.sourceRevision.source.bundleIdentifier,
                        deviceName: sample.device?.name ?? sample.sourceRevision.source.name
                    ))
                }
            }
            store.execute(query)
        }
    }

    /// All beat-to-beat series in a window, already converted.
    func ibiSeries(from start: Date, to end: Date) async throws -> [IBISeries] {
        let samples = try await heartbeatSeriesSamples(from: start, to: end)
        var out: [IBISeries] = []
        out.reserveCapacity(samples.count)
        for sample in samples {
            do { out.append(try await beats(in: sample)) }
            catch { log.error("failed to read series \(sample.uuid.uuidString, privacy: .public): \(error.localizedDescription)") }
        }
        return out.filter { $0.beats.count >= 2 }
    }

    // MARK: - Sleep

    func sleepProfile(from start: Date, to end: Date) async throws -> SleepProfile? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HealthTypes.sleepAnalysis,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
                }
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return nil }

        // Several sources can write overlapping sleep for the same night (the watch, the
        // phone, a third-party tracker). Mixing them produces impossible staging, so pick
        // the single source contributing the most staged time and use only that one.
        let staged = samples.filter {
            HKCategoryValueSleepAnalysis(rawValue: $0.value).map { $0 != .inBed } ?? false
        }
        let pool = staged.isEmpty ? samples : staged
        let bySource = Dictionary(grouping: pool) { $0.sourceRevision.source.bundleIdentifier }
        let chosen = bySource.max { a, b in
            a.value.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                < b.value.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        }?.value ?? pool

        let intervals = chosen.compactMap { sample -> SleepInterval? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
            return SleepInterval(stage: value.stage, start: sample.startDate, end: sample.endDate)
        }
        return intervals.isEmpty ? nil : SleepProfile(intervals: intervals)
    }

    // MARK: - Comparison data

    /// Apple's own SDNN samples in the window, as (date, ms) pairs.
    func appleSDNNSamples(from start: Date, to end: Date) async throws -> [(date: Date, sdnn: Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HealthTypes.hrvSDNN, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }
        return samples.map { ($0.startDate, $0.quantity.doubleValue(for: HealthTypes.ms)) }
    }

    func minimumHeartRate(from start: Date, to end: Date) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: HealthTypes.heartRate, quantitySamplePredicate: predicate,
                options: .discreteMin
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: statistics?.minimumQuantity()?
                        .doubleValue(for: HealthTypes.bpm))
                }
            }
            store.execute(query)
        }
    }

    func averageRespiratoryRate(from start: Date, to end: Date) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: HealthTypes.respiratoryRate, quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: statistics?.averageQuantity()?
                        .doubleValue(for: HealthTypes.breathsPerMinute))
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Background delivery

    /// Wake the app when new heartbeat series or sleep data lands, so a night is analysed
    /// without the user opening the app. Requires the
    /// `com.apple.developer.healthkit.background-delivery` entitlement.
    func startObserving(_ onChange: @escaping @Sendable () -> Void) async {
        for type in [HealthTypes.heartbeatSeries as HKSampleType, HealthTypes.sleepAnalysis] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if error == nil { onChange() }
                completionHandler()
            }
            store.execute(query)
            #if os(iOS)
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
            } catch {
                log.error("background delivery for \(type.identifier) unavailable: \(error.localizedDescription)")
            }
            #endif
        }
    }
}
