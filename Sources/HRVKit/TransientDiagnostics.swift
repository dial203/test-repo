import Foundation

/// How much of a record's RMSSD comes from a handful of large events rather than from
/// beat-to-beat modulation.
///
/// RMSSD is a root-*mean-square*, so its sum of squares is dominated by its largest terms.
/// One 600 ms swing contributes as much as four hundred beats of 30 ms normal variation.
/// On a real overnight chest-strap recording measured with this code, 1.65% of successive
/// differences — 467 of 28,219 — accounted for **56% of the RMSSD variance**: pooled RMSSD
/// fell from 108 ms to 72 ms when those differences were excluded.
///
/// That matters because those large differences are mostly not artifacts. Arousals,
/// position changes, sighs and post-apnoeic recoveries are real physiology, but they are
/// not the vagal tone that RMSSD is being used as a proxy for. A whole-night RMSSD in
/// which half the variance comes from 1.65% of beats is closer to an arousal counter than
/// to an index of parasympathetic activity, and no amount of artifact correction changes
/// that — the events are real.
///
/// The practical consequence: report the median of short stable windows, not a pooled
/// whole-night value, and check this diagnostic before trusting either.
public struct TransientDiagnostics: Sendable, Hashable, Codable {

    /// Threshold on |ΔNN| above which a successive difference counts as a transient, ms.
    public let threshold: Double
    public let differenceCount: Int
    public let transientCount: Int
    /// RMSSD over all valid successive differences, ms.
    public let rmssd: Double
    /// RMSSD with transients excluded, ms.
    public let rmssdExcludingTransients: Double
    /// Share of the RMSSD sum of squares contributed by the transients, 0–1.
    public let varianceShare: Double
    /// Largest absolute successive difference, ms.
    public let largestDifference: Double

    public var transientFraction: Double {
        differenceCount > 0 ? Double(transientCount) / Double(differenceCount) : .nan
    }

    /// True when a small minority of differences carries most of the variance, which is
    /// the signature of a transient-dominated record.
    public var isTransientDominated: Bool {
        varianceShare > 0.30 && transientFraction < 0.05
    }

    /// 300 ms is a deliberate choice, not a physiological boundary: at a nocturnal rate of
    /// 50–60 bpm it is roughly a third of the interval, far larger than respiratory
    /// modulation produces beat to beat, and about the size of the step an arousal or a
    /// dropped beat creates.
    public static let defaultThreshold: Double = 300

    public static func compute(
        for segments: [IntervalSegment], threshold: Double = defaultThreshold
    ) -> TransientDiagnostics? {
        var differences: [Double] = []
        for segment in segments { differences.append(contentsOf: segment.successiveDifferences) }
        guard !differences.isEmpty else { return nil }

        let squares = differences.map { $0 * $0 }
        let total = squares.reduce(0, +)
        let keptIndices = differences.indices.filter { abs(differences[$0]) <= threshold }
        let keptTotal = keptIndices.reduce(0.0) { $0 + squares[$1] }

        return TransientDiagnostics(
            threshold: threshold,
            differenceCount: differences.count,
            transientCount: differences.count - keptIndices.count,
            rmssd: (total / Double(differences.count)).squareRoot(),
            rmssdExcludingTransients: keptIndices.isEmpty
                ? .nan
                : (keptTotal / Double(keptIndices.count)).squareRoot(),
            varianceShare: total > 0 ? 1 - keptTotal / total : 0,
            largestDifference: differences.map(abs).max() ?? 0
        )
    }
}

/// Splits a night where its variability regime changes.
///
/// A night is often not one population. On the real recording above, the first ~two hours
/// sat at 63–73 bpm with 5-minute RMSSD of 21–43 ms and no large differences at all, while
/// the remainder sat at 47–58 bpm with RMSSD of 90–160 ms and 2–6% of differences over
/// 300 ms. Those are different physiological states, and a single nightly number averages
/// across them in a way that is neither one nor the other — and that will move between
/// nights purely with how much of each state a night happened to contain.
///
/// This is a descriptive split to make the structure visible, not a sleep stager. If
/// staging is available, use it.
public enum RegimeSplit {

    public struct Window: Sendable, Hashable, Codable {
        public let start: Date
        public let meanHR: Double
        public let rmssd: Double
        public let transientFraction: Double
    }

    public struct Result: Sendable, Hashable, Codable {
        public let windows: [Window]
        /// Ratio of the highest to lowest 5-minute RMSSD, ignoring the extreme tails.
        public let rmssdSpread: Double
        /// Between-window CV of RMSSD, percent.
        public let coefficientOfVariation: Double
    }

    public static func describe(
        _ segments: [IntervalSegment],
        windowSeconds: TimeInterval = 300,
        threshold: Double = TransientDiagnostics.defaultThreshold
    ) -> Result? {
        let groups = NightAnalyzer.fixedWindows(
            segments, seconds: windowSeconds, minimumFill: 0.8
        )
        var windows: [Window] = []
        for group in groups {
            guard let first = group.first else { continue }
            let metrics = TimeDomain.metrics(for: group)
            guard metrics.rmssd.isFinite else { continue }
            let diagnostics = TransientDiagnostics.compute(for: group, threshold: threshold)
            windows.append(Window(
                start: first.start,
                meanHR: metrics.meanHR,
                rmssd: metrics.rmssd,
                transientFraction: diagnostics?.transientFraction ?? .nan
            ))
        }
        guard windows.count >= 3 else { return nil }

        let values = windows.map(\.rmssd)
        // Trimmed spread, so one contaminated window does not define the range.
        let low = Stats.percentile(values, 0.10), high = Stats.percentile(values, 0.90)
        return Result(
            windows: windows,
            rmssdSpread: low > 0 ? high / low : .nan,
            coefficientOfVariation: 100 * Stats.sd(values) / Stats.mean(values)
        )
    }
}
