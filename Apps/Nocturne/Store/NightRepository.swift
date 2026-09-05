import Foundation
import Observation
import SwiftData
import HRVKit
import os

/// Coordinates HealthKit reads, analysis and persistence.
@MainActor
@Observable
final class NightRepository {

    enum Status: Equatable {
        case idle
        case needsAuthorization
        case working(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var nights: [AnalysedNight] = []
    var settings: AnalysisSettings {
        didSet { settings.save() }
    }

    private let context: ModelContext
    private let health: HealthKitService
    private let log = Logger(subsystem: "app.nocturne", category: "repository")

    init(context: ModelContext, health: HealthKitService = .shared) {
        self.context = context
        self.health = health
        self.settings = .load()
        reloadFromStore()
    }

    // MARK: - Derived state

    var tonight: AnalysedNight? { nights.last }

    var baselineHistory: [BaselinePoint] {
        nights
            .filter { $0.summary.quality != .insufficient && $0.summary.lnRMSSD.isFinite }
            .map { BaselinePoint(nightOf: $0.summary.nightOf, lnRMSSD: $0.summary.lnRMSSD) }
    }

    /// Baseline for the most recent night, excluding that night from its own reference
    /// distribution — otherwise tonight pulls its own baseline toward itself.
    var currentBaseline: BaselineResult? {
        guard let tonight, tonight.summary.lnRMSSD.isFinite else { return nil }
        let history = baselineHistory.filter { $0.nightOf < tonight.summary.nightOf }
        guard !history.isEmpty else { return nil }
        return Baseline.evaluate(tonight: tonight.summary.lnRMSSD, history: history)
    }

    // MARK: - Loading

    func reloadFromStore() {
        let descriptor = FetchDescriptor<StoredNight>(
            sortBy: [SortDescriptor(\.nightOf, order: .forward)]
        )
        do {
            nights = try context.fetch(descriptor).compactMap { stored in
                do { return try stored.decoded() }
                catch { log.error("could not decode night \(stored.nightOf.description, privacy: .public): \(error.localizedDescription)"); return nil }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Refresh

    func requestAuthorization() async {
        do {
            try await health.requestAuthorization()
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Analyse last night and, if nothing is stored yet, backfill.
    func refresh(backfillDays: Int = 30) async {
        guard health.isAvailable else {
            status = .failed(HealthKitError.unavailable.localizedDescription)
            return
        }
        let builder = NightBuilder(health: health)
        let existing = Set(nights.map(\.summary.nightOf))

        status = .working("Reading last night")
        let lastNight = NightBuilder.nightLabel(for: Date().addingTimeInterval(-12 * 3600))
        do {
            let night = try await builder.build(nightOf: lastNight,
                                                configuration: settings.analysisConfiguration)
            if night.summary.quality != .insufficient { try store(night) }
        } catch {
            log.error("refresh failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            return
        }

        if nights.count < backfillDays {
            let produced = await builder.backfill(
                days: backfillDays,
                existing: existing.union([lastNight]),
                configuration: settings.analysisConfiguration
            ) { [weak self] done, total in
                self?.status = .working("Backfilling \(done) of \(total)")
            }
            for night in produced { try? store(night) }
        }

        reloadFromStore()
        status = .idle
    }

    /// Re-run every stored night under the current settings. Uses the retained raw beats,
    /// so no HealthKit access is needed and nothing is refetched.
    func reanalyseAll() async {
        status = .working("Re-analysing stored nights")
        let config = settings.analysisConfiguration
        for night in nights {
            let updated = NightBuilder.reanalyse(night, configuration: config)
            try? store(updated)
        }
        reloadFromStore()
        status = .idle
    }

    private func store(_ night: AnalysedNight) throws {
        let target = night.summary.nightOf
        let descriptor = FetchDescriptor<StoredNight>(
            predicate: #Predicate { $0.nightOf == target }
        )
        if let existing = try context.fetch(descriptor).first {
            try existing.update(from: night)
        } else {
            context.insert(try StoredNight(night))
        }
        try context.save()
    }

    func delete(nightOf: Date) {
        let descriptor = FetchDescriptor<StoredNight>(
            predicate: #Predicate { $0.nightOf == nightOf }
        )
        if let stored = try? context.fetch(descriptor).first {
            context.delete(stored)
            try? context.save()
            reloadFromStore()
        }
    }
}
