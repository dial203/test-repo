import Foundation

/// A single detected heartbeat, expressed as an offset from the start of a series.
///
/// This mirrors the shape of the data `HKHeartbeatSeriesQuery` hands back
/// (`timeSinceSeriesStart`, `precededByGap`) so the HealthKit layer can map onto it
/// without loss, but the type itself has no HealthKit dependency.
public struct Beat: Sendable, Hashable, Codable {
    /// Seconds since the start of the owning series.
    public let offset: TimeInterval
    /// `true` when the sensor lost the pulse before this beat, i.e. the interval ending
    /// at this beat is **not** a valid beat-to-beat interval and must not be used.
    public let precededByGap: Bool

    public init(offset: TimeInterval, precededByGap: Bool = false) {
        self.offset = offset
        self.precededByGap = precededByGap
    }
}

/// A contiguous run of beat-to-beat intervals with no detection gap inside it.
///
/// Every HRV statistic that involves a *successive difference* (RMSSD, SDSD, pNN50,
/// SD1, DFA) must be computed inside a segment and never across a segment boundary.
public struct IntervalSegment: Sendable, Hashable, Codable {
    /// Wall-clock time of the first beat that opens this segment.
    public let start: Date
    /// Beat-to-beat intervals in milliseconds.
    public let intervals: [Double]

    public init(start: Date, intervals: [Double]) {
        self.start = start
        self.intervals = intervals
    }

    public var count: Int { intervals.count }
    public var isEmpty: Bool { intervals.isEmpty }
    /// Duration covered by the intervals, in seconds.
    public var duration: TimeInterval { intervals.reduce(0, +) / 1000.0 }
    public var end: Date { start.addingTimeInterval(duration) }

    /// Successive differences in milliseconds. Length is `count - 1` (empty if `count < 2`).
    public var successiveDifferences: [Double] {
        guard intervals.count > 1 else { return [] }
        return zip(intervals.dropFirst(), intervals).map(-)
    }

    public func timeRange() -> Range<Date>? {
        guard !isEmpty else { return nil }
        return start ..< end
    }
}

/// Beat-to-beat (inter-beat interval) data for one recording window.
///
/// On Apple Watch this is one `HKHeartbeatSeriesSample`: typically ~60 s of beats
/// captured alongside a background SDNN measurement, or an arbitrarily long series
/// recorded by your own watchOS app via `HKHeartbeatSeriesBuilder`.
public struct IBISeries: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let start: Date
    public let beats: [Beat]
    /// Free-form provenance, e.g. `"com.apple.health"` vs. this app's own recorder.
    public let sourceIdentifier: String?
    public let deviceName: String?

    public init(
        id: UUID = UUID(),
        start: Date,
        beats: [Beat],
        sourceIdentifier: String? = nil,
        deviceName: String? = nil
    ) {
        self.id = id
        self.start = start
        self.beats = beats.sorted { $0.offset < $1.offset }
        self.sourceIdentifier = sourceIdentifier
        self.deviceName = deviceName
    }

    public var end: Date { start.addingTimeInterval(beats.last?.offset ?? 0) }
    public var duration: TimeInterval { (beats.last?.offset ?? 0) - (beats.first?.offset ?? 0) }

    /// Split the beat train into gap-free interval segments.
    ///
    /// A segment break is inserted when the sensor reported `precededByGap`, or when the
    /// raw interval exceeds `maxInterval` (a torn interval that the watch did not flag —
    /// in practice this happens when the wrist moves and detection resumes mid-cycle).
    ///
    /// - Parameters:
    ///   - maxInterval: intervals longer than this (ms) break the segment. 3000 ms ≈ 20 bpm.
    ///   - minSegmentLength: segments with fewer intervals than this are dropped.
    public func segments(maxInterval: Double = 3000, minSegmentLength: Int = 2) -> [IntervalSegment] {
        guard beats.count >= 2 else { return [] }
        var out: [IntervalSegment] = []
        var current: [Double] = []
        var currentStartOffset: TimeInterval = beats[0].offset

        func flush(_ startOffset: TimeInterval) {
            if current.count >= minSegmentLength {
                out.append(IntervalSegment(start: start.addingTimeInterval(startOffset),
                                           intervals: current))
            }
            current = []
        }

        for i in 1 ..< beats.count {
            let ms = (beats[i].offset - beats[i - 1].offset) * 1000.0
            if beats[i].precededByGap || ms > maxInterval || ms <= 0 {
                flush(currentStartOffset)
                currentStartOffset = beats[i].offset
                continue
            }
            if current.isEmpty { currentStartOffset = beats[i - 1].offset }
            current.append(ms)
        }
        flush(currentStartOffset)
        return out
    }

    /// Build a series from already-derived intervals (useful for tests and for importing
    /// chest-strap RR files during validation work).
    public static func fromIntervals(
        start: Date,
        intervalsMS: [Double],
        sourceIdentifier: String? = nil
    ) -> IBISeries {
        var beats: [Beat] = [Beat(offset: 0, precededByGap: false)]
        var t: TimeInterval = 0
        for ms in intervalsMS {
            t += ms / 1000.0
            beats.append(Beat(offset: t, precededByGap: false))
        }
        return IBISeries(start: start, beats: beats, sourceIdentifier: sourceIdentifier)
    }
}
