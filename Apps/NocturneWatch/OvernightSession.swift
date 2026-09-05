import Foundation
import HealthKit
import os

/// Keeps the watch's sensors and this app alive overnight by running a workout session.
///
/// **Read this before enabling it.** A workout session does *not* give the app access to
/// beat-to-beat data — Apple Watch exposes no live inter-beat intervals to third-party
/// apps under any circumstances. What a session does is hold heart-rate sampling at
/// roughly 1 Hz and keep the app running, which in practice tends to increase how often
/// watchOS records its own background heartbeat series. That effect is not documented by
/// Apple, this app does not assume it, and you should verify the yield for yourself by
/// comparing windows-per-night with and without a session on the Trend screen.
///
/// The costs are real and immediate: substantially higher overnight battery drain, and a
/// workout in your history and Activity rings every night. `.mindAndBody` is used so the
/// entry is at least honestly labelled and contributes no exercise minutes.
@MainActor
final class OvernightSession: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case running(since: Date)
        case ended(duration: TimeInterval)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentHeartRate: Double?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let log = Logger(subsystem: "app.nocturne.watch", category: "session")

    func start() {
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self

            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { [weak self] success, error in
                Task { @MainActor in
                    if let error {
                        self?.state = .failed(error.localizedDescription)
                    } else if success {
                        self?.state = .running(since: start)
                    }
                }
            }
            self.session = session
            self.builder = builder
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard let session, let builder else { return }
        let end = Date()
        session.end()
        builder.endCollection(withEnd: end) { [weak self] _, _ in
            builder.finishWorkout { _, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.log.error("finishWorkout: \(error.localizedDescription)") }
                    if case let .running(since) = self.state {
                        self.state = .ended(duration: end.timeIntervalSince(since))
                    } else {
                        self.state = .idle
                    }
                    self.session = nil
                    self.builder = nil
                }
            }
        }
    }
}

extension OvernightSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}

extension OvernightSession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard collectedTypes.contains(HKQuantityType(.heartRate)),
              let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate)),
              let bpm = statistics.mostRecentQuantity()?
                .doubleValue(for: .count().unitDivided(by: .minute()))
        else { return }
        Task { @MainActor in self.currentHeartRate = bpm }
    }
}
