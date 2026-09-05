import Foundation
import HRVKit
import os

/// Extra context pulled from HealthKit that sits alongside the HRV analysis.
struct NightContext: Sendable, Codable, Hashable {
    var appleSDNNSamples: [AppleSDNN] = []
    var minimumHeartRate: Double?
    var averageRespiratoryRate: Double?

    struct AppleSDNN: Sendable, Codable, Hashable {
        let date: Date
        let sdnn: Double
    }

    /// Apple's SDNN paired with this app's own SDNN for the window containing it.
    ///
    /// Worth surfacing: the two are computed from the same beats, so a systematic
    /// difference is a processing difference, not a physiological one.
    func pairedWithOwnWindows(_ windows: [HRVWindow]) -> [(apple: Double, own: Double)] {
        appleSDNNSamples.compactMap { sample in
            guard let w = windows.first(where: { $0.start <= sample.date && sample.date < $0.end }),
                  w.timeDomain.sdnn.isFinite else { return nil }
            return (sample.sdnn, w.timeDomain.sdnn)
        }
    }
}

struct AnalysedNight: Sendable, Codable, Hashable, Identifiable {
    var id: Date { summary.nightOf }
    let summary: NightSummary
    let context: NightContext
    /// The raw series, kept so the analysis can be re-run under different settings and
    /// so the export can emit beat-level data.
    let rawSeries: [IBISeries]
    let analysedAt: Date
    let configuration: NightAnalysisConfiguration
}

/// Turns a calendar date into an analysed night.
@MainActor
struct NightBuilder {

    let health: HealthKitService
    private let log = Logger(subsystem: "app.nocturne", category: "nightbuilder")

    /// A night labelled *D* is searched for between 18:00 on D and 12:00 on D+1.
    /// Sleep that begins after midnight still belongs to the previous evening's label,
    /// which is the convention every training-monitoring dataset uses.
    static func searchWindow(for nightOf: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let day = calendar.startOfDay(for: nightOf)
        let start = calendar.date(byAdding: .hour, value: 18, to: day)!
        let end = calendar.date(byAdding: .hour, value: 36, to: day)!   // noon the next day
        return (start, end)
    }

    /// The night label for a moment in time: anything before noon belongs to the previous
    /// calendar day.
    static func nightLabel(for date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        return hour < 12 ? calendar.date(byAdding: .day, value: -1, to: day)! : day
    }

    func build(
        nightOf: Date,
        configuration: NightAnalysisConfiguration = .standard
    ) async throws -> AnalysedNight {
        let window = Self.searchWindow(for: nightOf)
        let sleep = try await health.sleepProfile(from: window.start, to: window.end)
        let series = try await health.ibiSeries(from: window.start, to: window.end)

        // Physiological context is scoped to the sleep period when staging exists,
        // otherwise to the whole search window.
        let contextRange = sleep?.mainSleepWindow ?? (window.start ..< window.end)
        async let apple = health.appleSDNNSamples(from: contextRange.lowerBound, to: contextRange.upperBound)
        async let minHR = health.minimumHeartRate(from: contextRange.lowerBound, to: contextRange.upperBound)
        async let respiration = health.averageRespiratoryRate(from: contextRange.lowerBound, to: contextRange.upperBound)

        let context = NightContext(
            appleSDNNSamples: try await apple.map { NightContext.AppleSDNN(date: $0.date, sdnn: $0.sdnn) },
            minimumHeartRate: try await minHR,
            averageRespiratoryRate: try await respiration
        )

        let summary = NightAnalyzer.analyze(
            series: series,
            sleep: sleep,
            nightOf: Calendar.current.startOfDay(for: nightOf),
            configuration: configuration
        )
        log.info("""
            night \(nightOf.description, privacy: .public): \(series.count) series, \
            \(summary.windows.count) windows, quality \(summary.quality.rawValue, privacy: .public)
            """)

        return AnalysedNight(
            summary: summary,
            context: context,
            rawSeries: series,
            analysedAt: Date(),
            configuration: configuration
        )
    }

    /// Re-run the analysis on already-fetched beats. Cheap, and the point of keeping the
    /// raw series: changing a preprocessing setting must not require another night's wait.
    static func reanalyse(
        _ night: AnalysedNight,
        configuration: NightAnalysisConfiguration
    ) -> AnalysedNight {
        AnalysedNight(
            summary: NightAnalyzer.analyze(
                series: night.rawSeries,
                sleep: night.summary.sleep,
                nightOf: night.summary.nightOf,
                configuration: configuration
            ),
            context: night.context,
            rawSeries: night.rawSeries,
            analysedAt: Date(),
            configuration: configuration
        )
    }

    /// Build every night in a range that is not already stored.
    func backfill(
        days: Int,
        existing: Set<Date>,
        configuration: NightAnalysisConfiguration = .standard,
        progress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> [AnalysedNight] {
        let calendar = Calendar.current
        var out: [AnalysedNight] = []
        let targets = (1 ... max(1, days)).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: Date()))
        }.filter { !existing.contains($0) }

        for (i, day) in targets.enumerated() {
            progress(i + 1, targets.count)
            do {
                let night = try await build(nightOf: day, configuration: configuration)
                if night.summary.quality != .insufficient { out.append(night) }
            } catch {
                log.error("backfill failed for \(day.description, privacy: .public): \(error.localizedDescription)")
            }
        }
        return out
    }
}
