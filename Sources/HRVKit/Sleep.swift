import Foundation

/// Sleep stage, mapped 1:1 from `HKCategoryValueSleepAnalysis` (iOS 16+).
public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case inBed
    case awake
    case core          // HKCategoryValueSleepAnalysis.asleepCore
    case deep          // .asleepDeep
    case rem           // .asleepREM
    case unspecified   // .asleepUnspecified, and the deprecated .asleep

    public var isAsleep: Bool {
        switch self {
        case .core, .deep, .rem, .unspecified: return true
        case .inBed, .awake: return false
        }
    }
}

public struct SleepInterval: Sendable, Hashable, Codable {
    public let stage: SleepStage
    public let start: Date
    public let end: Date
    public init(stage: SleepStage, start: Date, end: Date) {
        self.stage = stage; self.start = start; self.end = end
    }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// One night's sleep staging, already de-duplicated to a single source.
public struct SleepProfile: Sendable, Hashable, Codable {
    public let intervals: [SleepInterval]

    public init(intervals: [SleepInterval]) {
        self.intervals = intervals.sorted { $0.start < $1.start }
    }

    /// First asleep interval start.
    public var sleepOnset: Date? { intervals.first(where: { $0.stage.isAsleep })?.start }
    /// Last asleep interval end.
    public var finalAwakening: Date? { intervals.last(where: { $0.stage.isAsleep })?.end }
    /// Sum of asleep intervals.
    public var totalSleepTime: TimeInterval {
        intervals.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.duration }
    }
    public var timeInBed: TimeInterval {
        guard let s = intervals.first?.start, let e = intervals.last?.end else { return 0 }
        return e.timeIntervalSince(s)
    }
    /// Total sleep time / time in bed.
    public var sleepEfficiency: Double {
        timeInBed > 0 ? totalSleepTime / timeInBed : .nan
    }

    public func duration(of stage: SleepStage) -> TimeInterval {
        intervals.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
    }

    /// Stage covering the largest share of a time range, ignoring `inBed` unless it is
    /// the only thing present.
    public func dominantStage(from start: Date, to end: Date) -> SleepStage? {
        var totals: [SleepStage: TimeInterval] = [:]
        for iv in intervals {
            let lo = max(iv.start, start), hi = min(iv.end, end)
            guard hi > lo else { continue }
            totals[iv.stage, default: 0] += hi.timeIntervalSince(lo)
        }
        let staged = totals.filter { $0.key != .inBed }
        return (staged.isEmpty ? totals : staged).max(by: { $0.value < $1.value })?.key
    }

    /// The window this library uses when a caller asks for "the sleeping period":
    /// sleep onset to final awakening.
    public var mainSleepWindow: Range<Date>? {
        guard let onset = sleepOnset, let wake = finalAwakening, wake > onset else { return nil }
        return onset ..< wake
    }
}
