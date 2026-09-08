import Foundation

/// How a beat was classified by the adaptive-threshold detector.
public enum BeatClassification: String, Sendable, Codable, CaseIterable {
    case normal
    case ectopic
    case missed
    case extra
    case longShort
}

/// Counts and rates from one correction pass.
public struct ArtifactReport: Sendable, Hashable, Codable {
    public var beatCount: Int = 0
    public var ectopic: Int = 0
    public var missed: Int = 0
    public var extra: Int = 0
    public var longShort: Int = 0
    /// Intervals discarded by the physiological range gate (these become segment breaks,
    /// not corrections — a value outside the range means the data is absent, not wrong).
    public var rangeRejected: Int = 0
    /// Set when the |dRR| distribution had essentially no width, so the adaptive
    /// thresholds carried no information and correction was skipped. See
    /// `AdaptiveArtifactCorrector.degenerateDispersionRatio`.
    public var degenerateDispersion: Bool = false

    public var totalCorrected: Int { ectopic + missed + extra + longShort }

    /// Corrected beats as a proportion of beats examined. Kubios flags a recording as
    /// low quality above ~0.05; this library carries the number rather than hiding it.
    public var artifactFraction: Double {
        beatCount > 0 ? Double(totalCorrected + rangeRejected) / Double(beatCount) : .nan
    }

    public static func + (lhs: ArtifactReport, rhs: ArtifactReport) -> ArtifactReport {
        ArtifactReport(
            beatCount: lhs.beatCount + rhs.beatCount,
            ectopic: lhs.ectopic + rhs.ectopic,
            missed: lhs.missed + rhs.missed,
            extra: lhs.extra + rhs.extra,
            longShort: lhs.longShort + rhs.longShort,
            rangeRejected: lhs.rangeRejected + rhs.rangeRejected,
            degenerateDispersion: lhs.degenerateDispersion || rhs.degenerateDispersion
        )
    }

    public init(beatCount: Int = 0, ectopic: Int = 0, missed: Int = 0, extra: Int = 0,
                longShort: Int = 0, rangeRejected: Int = 0, degenerateDispersion: Bool = false) {
        self.beatCount = beatCount
        self.ectopic = ectopic
        self.missed = missed
        self.extra = extra
        self.longShort = longShort
        self.rangeRejected = rangeRejected
        self.degenerateDispersion = degenerateDispersion
    }
}

/// Adaptive artifact detection and correction after Lipponen & Tarvainen (2019).
///
/// This is an independent Swift port of the open reference implementation in NeuroKit2
/// (`signal_fixpeaks`, method `"kubios"`), which itself follows the published algorithm:
/// time-varying thresholds derived from the quartile deviation of the dRR and mRR
/// distributions, a four-way beat classification (ectopic / missed / extra / long-short),
/// and class-specific correction. It is *not* the Kubios binary, and it has not been
/// validated against it beat-for-beat — the accompanying test suite validates it against
/// synthetically inserted, deleted and displaced beats only. Report it that way in methods
/// sections.
///
/// Lipponen JA, Tarvainen MP. *A robust algorithm for heart rate variability time series
/// artefact correction using novel beat classification.* J Med Eng Technol 2019;43(3):173–181.
/// https://doi.org/10.1080/03091902.2019.1640306
public enum AdaptiveArtifactCorrector {

    /// Ratio of quartile deviation to median of |dRR| below which the beat train is
    /// treated as having no usable dispersion.
    ///
    /// Every threshold in this algorithm is proportional to the spread of a difference
    /// distribution. If that spread collapses — a metronomic or heavily quantised beat
    /// train — then every beat sits many "threshold units" from a distribution of zero
    /// width, and the detector labels the whole record as artifact. For a half-normal
    /// |dRR| distribution, which is what real beat-to-beat data looks like, this ratio is
    /// about 0.62; 0.10 therefore only ever fires on genuinely degenerate input.
    public static let degenerateDispersionRatio: Double = 0.10

    public struct Configuration: Sendable, Hashable, Codable {
        /// Ectopic subspace slope. Paper value 0.13.
        public var c1: Double = 0.13
        /// Ectopic subspace intercept. Paper value 0.17.
        public var c2: Double = 0.17
        /// Threshold scaling on the quartile deviation. Paper value 5.2.
        public var alpha: Double = 5.2
        /// Beats in the sliding window used for the time-varying thresholds. Paper value 91.
        public var windowWidth: Int = 91
        /// Order of the running median used to build the mRR series. Paper value 11.
        public var medianFilterOrder: Int = 11
        /// Re-run detection until the artifact count stops falling, up to this many passes.
        public var maxIterations: Int = 5
        /// Absolute floor on the adaptive thresholds, seconds. **This is a deliberate
        /// deviation from the published algorithm.**
        ///
        /// Both thresholds are `alpha` × the quartile deviation of a difference
        /// distribution. When that distribution is nearly degenerate — a metronomic
        /// rhythm, a heavily quantised IBI stream, or any near-deterministic beat train —
        /// the quartile deviation collapses toward zero, the normalised dRR series
        /// explodes, and essentially every beat is classified as an artifact. Floor the
        /// threshold at 20 ms and that failure mode disappears without touching the
        /// behaviour on real data, where `alpha` × QD is an order of magnitude larger and
        /// the floor never binds.
        public var minimumThreshold: Double = 0.020
        /// How far `RR/2` may sit from the local median before a long interval stops
        /// counting as a missed beat. **A second deliberate deviation from the published
        /// algorithm, and the one that matters most on high-HRV recordings.**
        ///
        /// The published missed-beat test is `|RR/2 − median| < th2`, where `th2` is
        /// `alpha` × the quartile deviation of the mRR distribution. That threshold scales
        /// with the record's own variability, so on a recording with large genuine
        /// variability it becomes vacuous. Measured on a real overnight chest-strap file
        /// with profound nocturnal bradycardia, `th2` reached 22% of the local interval at
        /// the median and 42% at the 95th percentile, and the test accepted 114 long
        /// intervals as missed beats when only 6 had `RR/2` anywhere near the local median.
        /// The other 108 had ratios of 1.3–1.7 — physiological transients, not two beats
        /// merged — and splitting those fabricates beats that never occurred while
        /// destroying the variability that made them interesting.
        ///
        /// A genuine single missed beat has `RR/2 ≈ median`. The default 0.15 accepts
        /// ratios of roughly 1.7–2.3 and rejects the rest, which is a discrimination the
        /// variability-scaled threshold cannot make on its own. Set it to `.infinity` to
        /// reproduce the published behaviour exactly.
        public var maximumRelativeDeviation: Double = 0.15
        /// What to do with beats that reach the long/short class.
        public var longShortPolicy: LongShortPolicy = .interpolate

        /// Long/short is the algorithm's "could not classify" bucket, so it is the class
        /// whose correction is least well justified. Interpolating it matches the published
        /// algorithm and Kubios; flagging it leaves genuinely variable beats alone at the
        /// cost of leaving real artifacts in. On a high-HRV record the two answers differ
        /// enough that the choice should be explicit.
        public enum LongShortPolicy: String, Sendable, Codable {
            /// Move the beat to the midpoint of its neighbours (published behaviour).
            case interpolate
            /// Count it, report it, change nothing.
            case flagOnly
        }

        public init() {}
        public init(c1: Double, c2: Double, alpha: Double, windowWidth: Int,
                    medianFilterOrder: Int, maxIterations: Int, minimumThreshold: Double = 0.020,
                    maximumRelativeDeviation: Double = 0.15,
                    longShortPolicy: LongShortPolicy = .interpolate) {
            self.c1 = c1; self.c2 = c2; self.alpha = alpha
            self.windowWidth = windowWidth
            self.medianFilterOrder = medianFilterOrder
            self.maxIterations = maxIterations
            self.minimumThreshold = minimumThreshold
            self.maximumRelativeDeviation = maximumRelativeDeviation
            self.longShortPolicy = longShortPolicy
        }

        public static let standard = Configuration()

        /// The published algorithm with no additional guards, for comparison.
        public static var publishedExactly: Configuration {
            var c = Configuration()
            c.maximumRelativeDeviation = .infinity
            c.minimumThreshold = 0
            return c
        }
    }

    struct Detection {
        var ectopic: [Int] = []
        var missed: [Int] = []
        var extra: [Int] = []
        var longShort: [Int] = []
        var total: Int { ectopic.count + missed.count + extra.count + longShort.count }
    }

    /// Correct a train of beat times (seconds, monotonically increasing).
    /// - Returns: corrected beat times and a count of what was changed.
    public static func correct(
        peakTimes: [Double],
        configuration: Configuration = .standard
    ) -> (peaks: [Double], report: ArtifactReport) {
        var peaks = peakTimes
        var report = ArtifactReport(beatCount: peakTimes.count)
        guard peaks.count >= 4 else { return (peaks, report) }

        if isDispersionDegenerate(peakTimes: peaks) {
            report.degenerateDispersion = true
            return (peaks, report)
        }

        var previousTotal = Int.max
        for _ in 0 ..< max(1, configuration.maxIterations) {
            let detection = findArtifacts(peaks: peaks, configuration: configuration)
            if detection.total == 0 || detection.total >= previousTotal { break }
            previousTotal = detection.total
            report.ectopic += detection.ectopic.count
            report.missed += detection.missed.count
            report.extra += detection.extra.count
            report.longShort += detection.longShort.count
            peaks = apply(detection, to: peaks, policy: configuration.longShortPolicy)
        }
        return (peaks, report)
    }

    /// True when |dRR| has essentially no spread relative to its own centre.
    static func isDispersionDegenerate(peakTimes: [Double]) -> Bool {
        guard peakTimes.count >= 4 else { return false }
        var absDRR: [Double] = []
        absDRR.reserveCapacity(peakTimes.count)
        var previous = peakTimes[1] - peakTimes[0]
        for i in 2 ..< peakTimes.count {
            let rr = peakTimes[i] - peakTimes[i - 1]
            absDRR.append(abs(rr - previous))
            previous = rr
        }
        let med = Stats.median(absDRR)
        guard med > 0 else { return true }
        return Stats.quartileDeviation(absDRR) / med < degenerateDispersionRatio
    }

    // MARK: - Detection

    static func findArtifacts(peaks: [Double], configuration c: Configuration) -> Detection {
        let n = peaks.count
        guard n >= 4 else { return Detection() }

        // rr[i] is the interval ending at peak i, in seconds. rr[0] is undefined and is
        // seeded with the mean so the median filter and thresholds behave at the edge.
        var rr = [Double](repeating: 0, count: n)
        for i in 1 ..< n { rr[i] = peaks[i] - peaks[i - 1] }
        rr[0] = Stats.mean(Array(rr[1...]))

        var drrs = [Double](repeating: 0, count: n)
        for i in 1 ..< n { drrs[i] = rr[i] - rr[i - 1] }
        drrs[0] = n > 1 ? Stats.mean(Array(drrs[1...])) : 0

        let th1 = threshold(drrs, alpha: c.alpha, window: c.windowWidth, floor: c.minimumThreshold)
        for i in 0 ..< n { drrs[i] = th1[i] != 0 ? drrs[i] / th1[i] : 0 }

        // Reflect-pad by 2 so the subspace lookups are defined at both edges,
        // matching the reference implementation.
        let pad = 2
        var padded = [Double](repeating: 0, count: n + 2 * pad)
        for i in 0 ..< pad { padded[i] = drrs[min(pad - i, n - 1)] }
        for i in 0 ..< n { padded[pad + i] = drrs[i] }
        for i in 0 ..< pad { padded[pad + n + i] = drrs[max(0, n - 2 - i)] }

        var s12 = [Double](repeating: 0, count: n)
        var s22 = [Double](repeating: 0, count: n)
        for d in pad ..< (pad + n) {
            let i = d - pad
            if padded[d] > 0 {
                s12[i] = max(padded[d - 1], padded[d + 1])
            } else if padded[d] < 0 {
                s12[i] = min(padded[d - 1], padded[d + 1])
            }
            if padded[d] >= 0 {
                s22[i] = min(padded[d + 1], padded[d + 2])
            } else {
                s22[i] = max(padded[d + 1], padded[d + 2])
            }
        }

        let medrr = Stats.runningMedian(rr, window: c.medianFilterOrder)
        var mrrs = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let v = rr[i] - medrr[i]
            mrrs[i] = v < 0 ? v * 2 : v
        }
        let th2 = threshold(mrrs, alpha: c.alpha, window: c.windowWidth, floor: c.minimumThreshold)
        for i in 0 ..< n { mrrs[i] = th2[i] != 0 ? mrrs[i] / th2[i] : 0 }

        var det = Detection()
        var i = 0
        while i < n - 2 {
            if abs(drrs[i]) <= 1 { i += 1; continue }

            let eq1 = drrs[i] > 1 && s12[i] < (-c.c1 * drrs[i] - c.c2)
            let eq2 = drrs[i] < -1 && s12[i] > (-c.c1 * drrs[i] + c.c2)
            if eq1 || eq2 { det.ectopic.append(i); i += 1; continue }

            if !(abs(drrs[i]) > 1 || abs(mrrs[i]) > 3) { i += 1; continue }

            var candidates = [i]
            if i + 2 < n, abs(drrs[i + 1]) < abs(drrs[i + 2]) { candidates.append(i + 1) }

            for j in candidates {
                guard j + 1 < n else { continue }
                let eq3 = drrs[j] > 1 && s22[j] < -1      // long
                let eq4 = abs(mrrs[j]) > 3                // long or short
                let eq5 = drrs[j] < -1 && s22[j] > 1      // short
                if !(eq3 || eq4 || eq5) { i += 1; continue }

                // A missed or extra beat is only credible when the reconstructed interval
                // lands near the local median in *relative* terms. th2 alone scales with
                // the record's variability and stops discriminating on high-HRV data.
                let relativeLimit = c.maximumRelativeDeviation.isFinite
                    ? c.maximumRelativeDeviation * medrr[j]
                    : Double.infinity
                let missedTolerance = min(th2[j], relativeLimit)
                let extraTolerance = min(th2[j], relativeLimit)
                let eq6 = abs(rr[j] / 2 - medrr[j]) < missedTolerance         // missed beat
                let eq7 = abs(rr[j] + rr[j + 1] - medrr[j]) < extraTolerance  // extra beat

                if eq5 && eq7 { det.extra.append(j); i += 1; continue }
                if eq3 && eq6 { det.missed.append(j); i += 1; continue }
                det.longShort.append(j)
                i += 1
            }
        }
        return det
    }

    /// alpha × quartile deviation of |signal| over a centred sliding window, with the
    /// window shrinking at the edges and an absolute floor applied (see
    /// `Configuration.minimumThreshold`).
    static func threshold(_ signal: [Double], alpha: Double, window: Int, floor: Double) -> [Double] {
        let a = signal.map(abs)
        return Stats.slidingQuantiles(a, window: window, probs: [0.25, 0.75])
            .map { max(alpha * ($0[1] - $0[0]) / 2.0, floor) }
    }

    // MARK: - Correction

    static func apply(
        _ detection: Detection, to peaks: [Double],
        policy: Configuration.LongShortPolicy = .interpolate
    ) -> [Double] {
        var peaks = peaks
        var missed = detection.missed
        var ectopic = detection.ectopic
        var longShort = detection.longShort

        if !detection.extra.isEmpty {
            let drop = Set(detection.extra)
            peaks = peaks.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            missed = shift(missed, after: detection.extra, by: -1)
            ectopic = shift(ectopic, after: detection.extra, by: -1)
            longShort = shift(longShort, after: detection.extra, by: -1)
        }

        if !missed.isEmpty {
            let valid = missed.filter { $0 > 1 && $0 < peaks.count }.sorted()
            var inserted: [Double] = peaks
            // Insert from the back so earlier indices stay valid.
            for idx in valid.reversed() {
                let newPeak = inserted[idx - 1] + (inserted[idx] - inserted[idx - 1]) / 2
                inserted.insert(newPeak, at: idx)
            }
            peaks = inserted
            ectopic = shift(ectopic, after: valid, by: 1)
            longShort = shift(longShort, after: valid, by: 1)
        }

        let toInterpolate = policy == .interpolate ? [ectopic, longShort] : [ectopic]
        for group in toInterpolate where !group.isEmpty {
            peaks = interpolateMisaligned(group, peaks: peaks)
        }
        return peaks
    }

    /// Move a misaligned beat onto the midpoint between its neighbours.
    static func interpolateMisaligned(_ indices: [Int], peaks: [Double]) -> [Double] {
        var peaks = peaks
        let valid = indices.filter { $0 > 1 && $0 < peaks.count - 1 }.sorted()
        for idx in valid {
            peaks[idx] = peaks[idx - 1] + (peaks[idx + 1] - peaks[idx - 1]) / 2
        }
        peaks.sort()
        return peaks
    }

    static func shift(_ indices: [Int], after sources: [Int], by delta: Int) -> [Int] {
        guard !indices.isEmpty else { return indices }
        var out = indices
        for s in sources {
            out = out.map { $0 > s ? $0 + delta : $0 }
        }
        return Array(Set(out)).sorted()
    }
}
