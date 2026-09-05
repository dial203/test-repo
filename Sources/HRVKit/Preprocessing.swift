import Foundation

/// Preprocessing policy applied before any HRV index is computed.
public struct PreprocessingConfiguration: Sendable, Hashable, Codable {
    /// Shortest physiologically plausible NN interval, ms (≈ 200 bpm).
    public var minNN: Double = 300
    /// Longest physiologically plausible NN interval, ms (≈ 24 bpm). Nocturnal bradycardia
    /// in endurance-trained people routinely reaches 35–40 bpm, so do not tighten this
    /// below ~1800 ms for athletic cohorts.
    public var maxNN: Double = 2000
    /// Raw interval above which the beat train is treated as broken rather than corrected, ms.
    public var segmentBreakInterval: Double = 3000
    /// Minimum intervals for a segment to be retained.
    public var minSegmentLength: Int = 5
    /// Run adaptive artifact detection/correction. Turn off to analyse raw detections,
    /// e.g. when quantifying how much the correction itself moves an index.
    public var applyAdaptiveCorrection: Bool = true
    public var corrector: AdaptiveArtifactCorrector.Configuration = .standard
    /// Windows above this corrected fraction are marked low quality.
    public var qualityArtifactCeiling: Double = 0.05

    public init() {}
    public static let standard = PreprocessingConfiguration()

    /// Correction disabled — raw NN as the watch reported them, range gate only.
    public static var rawWithRangeGateOnly: PreprocessingConfiguration {
        var c = PreprocessingConfiguration()
        c.applyAdaptiveCorrection = false
        return c
    }
}

/// A beat-to-beat series after gap splitting, range gating and artifact correction.
public struct CleanedSeries: Sendable, Hashable, Codable {
    public let sourceID: UUID
    public let start: Date
    public let segments: [IntervalSegment]
    public let report: ArtifactReport
    public let configuration: PreprocessingConfiguration

    public var nnCount: Int { segments.reduce(0) { $0 + $1.count } }
    public var coveredDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    public var isLowQuality: Bool { report.artifactFraction > configuration.qualityArtifactCeiling }
}

public enum Preprocessor {

    public static func clean(
        _ series: IBISeries,
        configuration: PreprocessingConfiguration = .standard
    ) -> CleanedSeries {
        let rawSegments = series.segments(
            maxInterval: configuration.segmentBreakInterval,
            minSegmentLength: 2
        )

        var out: [IntervalSegment] = []
        var report = ArtifactReport()

        for segment in rawSegments {
            var intervals = segment.intervals
            let segStart = segment.start
            report.beatCount += intervals.count + 1

            if configuration.applyAdaptiveCorrection, intervals.count >= 4 {
                // Rebuild a beat-time train (seconds) for the corrector, correct, then
                // difference back to intervals.
                var peaks: [Double] = [0]
                var t = 0.0
                for ms in intervals { t += ms / 1000.0; peaks.append(t) }
                let (corrected, r) = AdaptiveArtifactCorrector.correct(
                    peakTimes: peaks, configuration: configuration.corrector
                )
                report.ectopic += r.ectopic
                report.missed += r.missed
                report.extra += r.extra
                report.longShort += r.longShort
                intervals = zip(corrected.dropFirst(), corrected).map { ($0 - $1) * 1000.0 }
            }

            // Range gate: an out-of-range NN means data is absent, so it splits the
            // segment instead of being replaced with an interpolated value.
            var current: [Double] = []
            var offset: TimeInterval = 0
            var currentStartOffset: TimeInterval = 0
            func flush() {
                if current.count >= configuration.minSegmentLength {
                    out.append(IntervalSegment(
                        start: segStart.addingTimeInterval(currentStartOffset),
                        intervals: current
                    ))
                }
                current = []
            }
            for ms in intervals {
                if ms < configuration.minNN || ms > configuration.maxNN {
                    report.rangeRejected += 1
                    flush()
                    offset += ms / 1000.0
                    currentStartOffset = offset
                    continue
                }
                if current.isEmpty { currentStartOffset = offset }
                current.append(ms)
                offset += ms / 1000.0
            }
            flush()
        }

        return CleanedSeries(
            sourceID: series.id,
            start: series.start,
            segments: out.sorted { $0.start < $1.start },
            report: report,
            configuration: configuration
        )
    }

    /// Clean a night's worth of series and return them ordered in time.
    public static func clean(
        _ seriesList: [IBISeries],
        configuration: PreprocessingConfiguration = .standard
    ) -> [CleanedSeries] {
        seriesList
            .sorted { $0.start < $1.start }
            .map { clean($0, configuration: configuration) }
    }
}
