import Foundation

/// One analysis window and everything computed from it.
public struct HRVWindow: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let sleepStage: SleepStage?
    public let timeDomain: TimeDomainMetrics
    public let frequencyDomain: FrequencyDomainMetrics?
    public let spectralRefusal: SpectralRefusal?
    public let artifactFraction: Double
    public let isLowQuality: Bool
    /// The `IBISeries` this window came from, so a window can be traced back to a raw sample.
    public let sourceSeriesID: UUID

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// How the night is cut into windows.
public enum WindowingStrategy: Sendable, Hashable, Codable {
    /// One window per source series. This is the right choice for passively collected
    /// Apple Watch data, where each `HKHeartbeatSeriesSample` is already a discrete
    /// ~60 s measurement and re-windowing would only merge unrelated epochs.
    case nativeSeries
    /// Re-cut continuous recordings into fixed windows. Only meaningful when the beat
    /// train is continuous — i.e. data from this app's own watchOS recorder.
    case fixed(seconds: TimeInterval, minimumFill: Double)
}

/// How per-window values are collapsed into one number for the night.
public enum NightAggregator: Sendable, Hashable, Codable {
    case median
    case mean
    case trimmedMean(fraction: Double)
    /// Restrict to windows whose dominant stage is in the set, then aggregate.
    case stageRestricted(stages: [SleepStage], inner: [NightAggregator])
    /// Windows starting within `minutes` of sleep onset.
    case afterSleepOnset(minutes: Double, inner: [NightAggregator])
    /// Windows in the last `minutes` before final awakening.
    case beforeWake(minutes: Double, inner: [NightAggregator])

    /// Boxed recursion helper — `inner` is a single-element array only because Swift
    /// enums cannot hold themselves directly without indirection.
    static func wrap(_ a: NightAggregator) -> [NightAggregator] { [a] }
}

public struct NightAnalysisConfiguration: Sendable, Hashable, Codable {
    public var preprocessing: PreprocessingConfiguration = .standard
    public var windowing: WindowingStrategy = .nativeSeries
    public var bands: FrequencyBands = FrequencyBands()
    public var spectralMethod: SpectralMethod = .lombScargle()
    /// Attempt frequency-domain analysis at all. Off by default because passive Apple
    /// Watch windows are ~60 s, which cannot resolve LF (0.04 Hz needs ≥ 25 s per cycle
    /// and, conventionally, a 5 min record).
    public var computeFrequencyDomain: Bool = false
    public var computeNonlinear: Bool = false
    /// Drop windows whose corrected fraction exceeds the ceiling before aggregating.
    public var excludeLowQualityWindows: Bool = true
    /// Restrict analysis to sleep onset → final awakening when staging is available.
    public var restrictToMainSleepWindow: Bool = true
    /// Minimum retained windows before a night summary is considered reportable.
    public var minimumWindowsForSummary: Int = 3
    /// Minimum total analysed time before a night summary is considered reportable.
    public var minimumCoverageSeconds: TimeInterval = 300

    public init() {}
    public static let standard = NightAnalysisConfiguration()
}

public enum NightDataQuality: String, Sendable, Codable {
    case good
    /// Reportable but thin — treat the value as noisy and do not act on a single night.
    case sparse
    /// Not reportable.
    case insufficient
}

public struct NightSummary: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { nightOf }
    /// Calendar date the night is attributed to (the evening it began).
    public let nightOf: Date
    public let windows: [HRVWindow]
    public let quality: NightDataQuality

    /// Windows retained after quality and staging filters.
    public let usedWindowCount: Int
    /// Total analysed time, seconds.
    public let coverage: TimeInterval
    /// Corrected + rejected beats over all beats examined.
    public let artifactFraction: Double

    /// Primary nightly value: median of per-window RMSSD over retained windows.
    /// Median rather than mean because per-window RMSSD is right-skewed and a single
    /// motion-contaminated window can move a mean substantially.
    public let rmssd: Double
    public let lnRMSSD: Double
    public let sdnn: Double
    public let meanHR: Double
    public let minHR: Double
    public let pnn50: Double
    public let sd1: Double
    public let sd2: Double

    /// The same value under alternative aggregation rules, for sensitivity analysis.
    /// Keys are stable identifiers, e.g. `"rmssd.deep"`, `"rmssd.first30min"`.
    public let alternates: [String: Double]

    public let sleep: SleepProfile?
}

public enum NightAnalyzer {

    public static func analyze(
        series: [IBISeries],
        sleep: SleepProfile?,
        nightOf: Date,
        configuration: NightAnalysisConfiguration = .standard
    ) -> NightSummary {
        let cleaned = Preprocessor.clean(series, configuration: configuration.preprocessing)
        var windows: [HRVWindow] = []

        let bound: Range<Date>? = configuration.restrictToMainSleepWindow
            ? sleep?.mainSleepWindow : nil

        for clean in cleaned {
            let segmentGroups: [[IntervalSegment]]
            switch configuration.windowing {
            case .nativeSeries:
                segmentGroups = clean.segments.isEmpty ? [] : [clean.segments]
            case let .fixed(seconds, minimumFill):
                segmentGroups = fixedWindows(clean.segments, seconds: seconds, minimumFill: minimumFill)
            }

            for group in segmentGroups {
                guard let first = group.first, let last = group.last else { continue }
                let start = first.start, end = last.end
                if let bound, !(start < bound.upperBound && end > bound.lowerBound) { continue }

                let td = TimeDomain.metrics(for: group)
                guard td.nnCount >= 2 else { continue }

                var fd: FrequencyDomainMetrics?
                var refusal: SpectralRefusal?
                if configuration.computeFrequencyDomain,
                   let longest = group.max(by: { $0.count < $1.count }) {
                    switch FrequencyDomain.metrics(for: longest,
                                                   method: configuration.spectralMethod,
                                                   bands: configuration.bands) {
                    case let .success(m): fd = m
                    case let .failure(r): refusal = r
                    }
                }

                windows.append(HRVWindow(
                    id: UUID(),
                    start: start,
                    end: end,
                    sleepStage: sleep?.dominantStage(from: start, to: end),
                    timeDomain: td,
                    frequencyDomain: fd,
                    spectralRefusal: refusal,
                    artifactFraction: clean.report.artifactFraction,
                    isLowQuality: clean.isLowQuality,
                    sourceSeriesID: clean.sourceID
                ))
            }
        }

        windows.sort { $0.start < $1.start }

        var retained = windows
        if configuration.excludeLowQualityWindows {
            retained = retained.filter { !$0.isLowQuality }
        }

        let coverage = retained.reduce(0) { $0 + $1.timeDomain.coveredDuration }
        let totalReport = cleaned.reduce(ArtifactReport()) { $0 + $1.report }

        let quality: NightDataQuality
        if retained.count < configuration.minimumWindowsForSummary
            || coverage < configuration.minimumCoverageSeconds {
            quality = retained.isEmpty ? .insufficient : .sparse
        } else {
            quality = .good
        }

        func values(_ ws: [HRVWindow], _ key: (TimeDomainMetrics) -> Double) -> [Double] {
            ws.map { key($0.timeDomain) }.filter { $0.isFinite }
        }

        let rmssdValues = values(retained) { $0.rmssd }
        let rmssd = Stats.median(rmssdValues)

        // Alternative aggregations, computed so the choice of rule can be audited rather
        // than assumed. These are the ones that differ most in practice.
        var alternates: [String: Double] = [:]
        alternates["rmssd.median"] = rmssd
        alternates["rmssd.mean"] = Stats.mean(rmssdValues)
        alternates["rmssd.trimmedMean20"] = Stats.trimmedMean(rmssdValues, fraction: 0.20)
        for stage in [SleepStage.deep, .core, .rem] {
            let sub = retained.filter { $0.sleepStage == stage }
            alternates["rmssd.\(stage.rawValue)"] = Stats.median(values(sub) { $0.rmssd })
        }
        if let onset = sleep?.sleepOnset {
            for minutes in [30.0, 60.0, 240.0] {
                let cutoff = onset.addingTimeInterval(minutes * 60)
                let sub = retained.filter { $0.start >= onset && $0.start < cutoff }
                alternates["rmssd.first\(Int(minutes))min"] = Stats.median(values(sub) { $0.rmssd })
            }
        }
        if let wake = sleep?.finalAwakening {
            let cutoff = wake.addingTimeInterval(-60 * 60)
            let sub = retained.filter { $0.start >= cutoff }
            alternates["rmssd.last60min"] = Stats.median(values(sub) { $0.rmssd })
        }
        alternates["lnRMSSD.medianOfLogs"] = Stats.median(values(retained) { $0.lnRMSSD })

        let hrValues = values(retained) { $0.meanHR }

        return NightSummary(
            nightOf: nightOf,
            windows: windows,
            quality: quality,
            usedWindowCount: retained.count,
            coverage: coverage,
            artifactFraction: totalReport.artifactFraction,
            rmssd: rmssd,
            // ln of the median RMSSD, not the median of the logs — the two differ only
            // by a monotone transform of an odd-length sample, but stay consistent so
            // baselines are comparable. Both are exposed via `alternates`.
            lnRMSSD: log(rmssd),
            sdnn: Stats.median(values(retained) { $0.sdnn }),
            meanHR: Stats.median(hrValues),
            minHR: hrValues.min() ?? .nan,
            pnn50: Stats.median(values(retained) { $0.pnn50 }),
            sd1: Stats.median(values(retained) { $0.sd1 }),
            sd2: Stats.median(values(retained) { $0.sd2 }),
            alternates: alternates,
            sleep: sleep
        )
    }

    /// Cut gap-free segments into fixed-duration windows, keeping only windows whose
    /// analysed time fills at least `minimumFill` of the nominal duration.
    static func fixedWindows(
        _ segments: [IntervalSegment], seconds: TimeInterval, minimumFill: Double
    ) -> [[IntervalSegment]] {
        guard let first = segments.first?.start, let last = segments.map(\.end).max() else { return [] }
        var out: [[IntervalSegment]] = []
        var cursor = first
        while cursor < last {
            let windowEnd = cursor.addingTimeInterval(seconds)
            var group: [IntervalSegment] = []
            for seg in segments {
                var t = seg.start
                var kept: [Double] = []
                var keptStart: Date?
                for ms in seg.intervals {
                    let next = t.addingTimeInterval(ms / 1000.0)
                    if t >= cursor && next <= windowEnd {
                        if keptStart == nil { keptStart = t }
                        kept.append(ms)
                    } else if !kept.isEmpty {
                        group.append(IntervalSegment(start: keptStart!, intervals: kept))
                        kept = []; keptStart = nil
                    }
                    t = next
                }
                if !kept.isEmpty, let ks = keptStart {
                    group.append(IntervalSegment(start: ks, intervals: kept))
                }
            }
            let filled = group.reduce(0) { $0 + $1.duration }
            if filled >= seconds * minimumFill { out.append(group) }
            cursor = windowEnd
        }
        return out
    }
}
