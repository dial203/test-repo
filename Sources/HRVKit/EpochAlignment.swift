import Foundation

/// Pairs a continuous criterion recording with the sparse windows a watch produces.
///
/// This is the step that decides whether a method comparison means anything, and it is
/// the one most often got wrong. Apple Watch gives you a handful of ~60 s epochs at times
/// you do not control; a chest strap gives you a continuous night. Comparing the watch's
/// 60 s RMSSD against a whole-night strap RMSSD is not an agreement analysis — the two
/// numbers are estimates of different quantities, and RMSSD over eight hours is not RMSSD
/// over one minute. What has to be compared is the strap's RMSSD **over the same 60
/// seconds**, extracted from the continuous record.
///
/// Two things then have to be handled honestly:
///
/// 1. **Clock offset.** The watch and the strap's recorder keep independent clocks, drift
///    apart, and are set from different sources. An offset of a few seconds changes which
///    beats fall inside a 60 s epoch, and on a 60-beat window a handful of swapped beats
///    moves RMSSD measurably. The offset is estimated from the data rather than assumed
///    to be zero.
/// 2. **Coverage.** If the strap dropped out for part of an epoch, the criterion value is
///    computed from fewer beats than the watch's and is not comparable. Epochs below a
///    coverage threshold are excluded, and the count of exclusions is reported.
public struct AlignedEpoch: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    /// Night this epoch belongs to, `yyyy-MM-dd`. The clustering unit for the statistics.
    public let nightOf: String
    public let sleepStage: SleepStage?

    /// Metrics from the device under test (the watch).
    public let test: TimeDomainMetrics
    /// Metrics from the criterion (the strap), over the same wall-clock interval.
    public let reference: TimeDomainMetrics

    /// Proportion of the epoch the criterion record actually covers.
    public let referenceCoverage: Double
    public let testArtifactFraction: Double
    public let referenceArtifactFraction: Double

    public func pair(_ metric: (TimeDomainMetrics) -> Double) -> PairedObservation? {
        let r = metric(reference), t = metric(test)
        guard r.isFinite, t.isFinite else { return nil }
        return PairedObservation(reference: r, test: t, cluster: nightOf)
    }
}

public struct AlignmentReport: Sendable, Hashable, Codable {
    public let matched: Int
    /// Watch epochs with no overlapping criterion data at all.
    public let noReferenceData: Int
    /// Watch epochs where the criterion covered too little of the window.
    public let insufficientCoverage: Int
    /// Epochs dropped because either side exceeded the artifact ceiling.
    public let excludedForArtifacts: Int
    /// Clock offset applied, seconds. Positive means the criterion clock ran ahead.
    public let clockOffset: TimeInterval
    /// Peak normalised cross-correlation at the chosen offset. Low values mean the offset
    /// estimate is not trustworthy and the alignment should be treated as suspect.
    public let offsetConfidence: Double

    /// Fingerprint of the preprocessing applied to the criterion record here.
    public let referencePreprocessingHash: String
    /// Fingerprint of the preprocessing that produced the test windows, when the caller
    /// declared it.
    public let testPreprocessingHash: String?

    /// `false` when the two sides were preprocessed differently.
    ///
    /// This matters more than it looks. If the watch's windows were artifact-corrected and
    /// the criterion was not — or the two used different interval ranges — then the
    /// measured difference between devices is partly a difference between pipelines, and
    /// no amount of careful statistics downstream will separate them. `nil` means the
    /// caller did not declare the test-side configuration, so nothing could be checked.
    public var preprocessingMatched: Bool? {
        guard let testPreprocessingHash else { return nil }
        return testPreprocessingHash == referencePreprocessingHash
    }
}

public struct AlignmentConfiguration: Sendable, Hashable, Codable {
    /// Minimum proportion of the test window the criterion must cover.
    public var minimumCoverage: Double = 0.90
    /// Artifact ceiling applied to both sides independently.
    public var artifactCeiling: Double = 0.05
    /// Range searched when estimating the clock offset, seconds either side.
    public var maximumClockOffset: TimeInterval = 120
    /// Estimate the offset from the data. Turn it off only if both recorders are known to
    /// share a clock source.
    public var estimateClockOffset: Bool = true
    public var preprocessing: PreprocessingConfiguration = .standard

    public init() {}
    public static let standard = AlignmentConfiguration()
}

/// Segments indexed by absolute beat time, so extracting a window is a binary search
/// rather than a walk over the whole record.
///
/// Without this, aligning N windows against a continuous night costs
/// O(N × total intervals): a fortnight of chest-strap data against a couple of hundred
/// watch windows is tens of millions of steps, and a year is unusable.
public struct IntervalIndex: Sendable {
    /// Absolute beat times, seconds since the reference date. One more entry than intervals.
    let beatTimes: [Double]
    let intervals: [Double]

    public init(_ segment: IntervalSegment) {
        var times: [Double] = [segment.start.timeIntervalSinceReferenceDate]
        times.reserveCapacity(segment.count + 1)
        var t = times[0]
        for interval in segment.intervals {
            t += interval / 1000.0
            times.append(t)
        }
        beatTimes = times
        intervals = segment.intervals
    }

    public static func build(_ segments: [IntervalSegment]) -> [IntervalIndex] {
        segments.map(IntervalIndex.init)
    }

    var startTime: Double { beatTimes.first ?? .infinity }
    var endTime: Double { beatTimes.last ?? -.infinity }

    /// First index whose beat time is >= `value`.
    func lowerBound(_ value: Double) -> Int {
        var low = 0, high = beatTimes.count
        while low < high {
            let mid = (low + high) / 2
            if beatTimes[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

public enum EpochAligner {

    /// Align a continuous criterion recording to a set of test windows.
    ///
    /// - Parameters:
    ///   - testWindows: the watch's analysis windows, as produced by `NightAnalyzer`.
    ///   - reference: continuous criterion series — one per night is typical.
    ///   - testPreprocessing: the preprocessing that produced `testWindows`. Pass it and
    ///     the report will confirm both sides were treated identically; omit it and that
    ///     check cannot be made.
    public static func align(
        testWindows: [HRVWindow],
        reference: [IBISeries],
        configuration: AlignmentConfiguration = .standard,
        testPreprocessing: PreprocessingConfiguration? = nil,
        calendar: Calendar = .current
    ) -> (epochs: [AlignedEpoch], report: AlignmentReport) {
        let referenceHash = ConfigurationFingerprint.hash(of: configuration.preprocessing)
        let testHash = testPreprocessing.map { ConfigurationFingerprint.hash(of: $0) }
        let cleanedReference = Preprocessor.clean(reference, configuration: configuration.preprocessing)
        let referenceSegments = cleanedReference.flatMap(\.segments).sorted { $0.start < $1.start }
        let referenceIndex = IntervalIndex.build(referenceSegments)
        guard !referenceSegments.isEmpty, !testWindows.isEmpty else {
            return ([], AlignmentReport(
                matched: 0, noReferenceData: testWindows.count, insufficientCoverage: 0,
                excludedForArtifacts: 0, clockOffset: 0, offsetConfidence: 0,
                referencePreprocessingHash: referenceHash, testPreprocessingHash: testHash
            ))
        }

        let offsetEstimate = configuration.estimateClockOffset
            ? estimateClockOffset(
                testWindows: testWindows, referenceSegments: referenceSegments,
                maximumOffset: configuration.maximumClockOffset
            )
            : (offset: 0.0, confidence: 1.0)

        let referenceArtifact = cleanedReference.isEmpty
            ? Double.nan
            : (cleanedReference.reduce(ArtifactReport()) { $0 + $1.report }).artifactFraction

        var epochs: [AlignedEpoch] = []
        var noData = 0, lowCoverage = 0, artifactExcluded = 0

        for window in testWindows {
            // Shift the window into the criterion's clock.
            let start = window.start.addingTimeInterval(offsetEstimate.offset)
            let end = window.end.addingTimeInterval(offsetEstimate.offset)
            let extracted = extract(referenceIndex, from: start, to: end)
            guard !extracted.isEmpty else { noData += 1; continue }

            let nominal = end.timeIntervalSince(start)
            let covered = extracted.reduce(0) { $0 + $1.duration }
            let coverage = nominal > 0 ? covered / nominal : 0
            guard coverage >= configuration.minimumCoverage else { lowCoverage += 1; continue }

            let referenceMetrics = TimeDomain.metrics(for: extracted)
            guard referenceMetrics.nnCount >= 2 else { noData += 1; continue }

            if window.artifactFraction > configuration.artifactCeiling
                || (referenceArtifact.isFinite && referenceArtifact > configuration.artifactCeiling) {
                artifactExcluded += 1
                continue
            }

            epochs.append(AlignedEpoch(
                start: window.start,
                end: window.end,
                nightOf: nightKey(for: window.start, calendar: calendar),
                sleepStage: window.sleepStage,
                test: window.timeDomain,
                reference: referenceMetrics,
                referenceCoverage: coverage,
                testArtifactFraction: window.artifactFraction,
                referenceArtifactFraction: referenceArtifact
            ))
        }

        return (epochs, AlignmentReport(
            matched: epochs.count,
            noReferenceData: noData,
            insufficientCoverage: lowCoverage,
            excludedForArtifacts: artifactExcluded,
            clockOffset: offsetEstimate.offset,
            offsetConfidence: offsetEstimate.confidence,
            referencePreprocessingHash: referenceHash,
            testPreprocessingHash: testHash
        ))
    }

    /// Intervals from the criterion record that fall wholly inside the window.
    ///
    /// Wholly inside, not merely overlapping: a partially included interval would be
    /// counted with a truncated duration, and the successive difference at the boundary
    /// would be taken against a beat outside the epoch.
    static func extract(
        _ segments: [IntervalSegment], from start: Date, to end: Date
    ) -> [IntervalSegment] {
        extract(IntervalIndex.build(segments), from: start, to: end)
    }

    static func extract(
        _ indexes: [IntervalIndex], from start: Date, to end: Date
    ) -> [IntervalSegment] {
        let lower = start.timeIntervalSinceReferenceDate
        let upper = end.timeIntervalSinceReferenceDate
        var out: [IntervalSegment] = []

        for index in indexes {
            guard index.endTime > lower, index.startTime < upper else { continue }
            // Interval j runs from beat j to beat j+1, so the first wholly contained
            // interval starts at the first beat at or after `lower`, and the last ends at
            // the last beat at or before `upper`.
            let firstBeat = index.lowerBound(lower)
            var lastBeat = index.lowerBound(upper)
            if lastBeat >= index.beatTimes.count || index.beatTimes[lastBeat] > upper {
                lastBeat -= 1
            }
            guard lastBeat > firstBeat, firstBeat < index.intervals.count else { continue }
            let upperInterval = min(lastBeat, index.intervals.count)
            guard upperInterval > firstBeat else { continue }

            out.append(IntervalSegment(
                start: Date(timeIntervalSinceReferenceDate: index.beatTimes[firstBeat]),
                intervals: Array(index.intervals[firstBeat ..< upperInterval])
            ))
        }
        return out.filter { $0.count >= 2 }
    }

    /// Estimate the offset between the two clocks by cross-correlating instantaneous
    /// heart rate resampled at 1 Hz.
    ///
    /// Heart rate rather than the RR series itself because the two recorders detect
    /// different numbers of beats, so an RR-index correlation would be meaningless, while
    /// the heart-rate-versus-time curve is the same physiological signal in both.
    static func estimateClockOffset(
        testWindows: [HRVWindow], referenceSegments: [IntervalSegment], maximumOffset: TimeInterval
    ) -> (offset: TimeInterval, confidence: Double) {
        // The test side gives one mean HR per window: a sparse, irregular series.
        let testPoints: [(t: Date, hr: Double)] = testWindows.compactMap {
            guard $0.timeDomain.meanHR.isFinite else { return nil }
            return ($0.start.addingTimeInterval($0.duration / 2), $0.timeDomain.meanHR)
        }
        guard testPoints.count >= 4 else { return (0, 0) }

        // Reference HR as a function of time, one point per beat.
        var referencePoints: [(t: Date, hr: Double)] = []
        for segment in referenceSegments {
            var cursor = segment.start
            for interval in segment.intervals {
                referencePoints.append((cursor, 60_000.0 / interval))
                cursor = cursor.addingTimeInterval(interval / 1000.0)
            }
        }
        guard referencePoints.count >= 60 else { return (0, 0) }

        // Beat times are already sorted, so bound the window by binary search rather than
        // scanning the whole record. A full night of chest-strap data is tens of thousands
        // of beats and the search tries a few hundred candidate offsets against every
        // window; the linear form turns that into hundreds of millions of comparisons.
        let times = referencePoints.map { $0.t.timeIntervalSinceReferenceDate }
        let rates = referencePoints.map(\.hr)

        func lowerBound(_ value: Double) -> Int {
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < value { low = mid + 1 } else { high = mid }
            }
            return low
        }

        func referenceHR(at time: Date, window: TimeInterval) -> Double? {
            let centre = time.timeIntervalSinceReferenceDate
            let from = lowerBound(centre - window / 2)
            let to = lowerBound(centre + window / 2)
            guard to > from else { return nil }
            var sum = 0.0
            for i in from ..< to { sum += rates[i] }
            return sum / Double(to - from)
        }

        var best = (offset: 0.0, correlation: -Double.infinity)
        // 1 s resolution over the search range.
        for offsetSeconds in stride(from: -maximumOffset, through: maximumOffset, by: 1.0) {
            var testValues: [Double] = [], referenceValues: [Double] = []
            for point in testPoints {
                guard let hr = referenceHR(
                    at: point.t.addingTimeInterval(offsetSeconds), window: 60
                ) else { continue }
                testValues.append(point.hr)
                referenceValues.append(hr)
            }
            guard testValues.count >= 4 else { continue }
            let correlation = pearson(testValues, referenceValues)
            if correlation > best.correlation { best = (offsetSeconds, correlation) }
        }

        // A weak peak means the estimate is not trustworthy; report zero offset and let
        // the caller see the low confidence rather than silently shifting the data.
        guard best.correlation > 0.5 else { return (0, max(0, best.correlation)) }
        return (best.offset, best.correlation)
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 2 else { return .nan }
        let mx = Stats.mean(x), my = Stats.mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
        }
        guard sxx > 0, syy > 0 else { return .nan }
        return sxy / (sxx * syy).squareRoot()
    }

    static func nightKey(for date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let day = calendar.startOfDay(for: date)
        let labelled = hour < 12
            ? calendar.date(byAdding: .day, value: -1, to: day) ?? day
            : day
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: labelled)
    }
}
