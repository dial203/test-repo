import Foundation

/// Time-domain HRV indices, computed over one or more gap-free segments.
///
/// The important structural point: successive-difference statistics (RMSSD, SDSD, pNN50,
/// pNN20) are pooled *across* segments but never computed *through* a gap. Concatenating
/// segments and differencing the joined array is a common and silent source of inflated
/// RMSSD; this type does not do that.
public struct TimeDomainMetrics: Sendable, Hashable, Codable {
    /// Number of NN intervals contributing.
    public let nnCount: Int
    /// Number of valid successive differences contributing (≤ nnCount − 1 when segmented).
    public let differenceCount: Int
    /// Total time covered by the contributing intervals, seconds.
    public let coveredDuration: TimeInterval

    /// Mean NN interval, ms.
    public let meanNN: Double
    /// Median NN interval, ms.
    public let medianNN: Double
    /// Mean heart rate derived from mean NN, bpm (60000 / meanNN).
    public let meanHR: Double
    /// SD of all NN intervals, ms. Sample (n−1).
    public let sdnn: Double
    /// Root mean square of successive differences, ms.
    public let rmssd: Double
    /// Natural log of RMSSD. Approximately normally distributed; the form to trend and to
    /// run parametric statistics on.
    public let lnRMSSD: Double
    /// SD of successive differences, ms.
    public let sdsd: Double
    /// Percentage of successive differences greater than 50 ms.
    public let pnn50: Double
    /// Percentage of successive differences greater than 20 ms.
    public let pnn20: Double
    /// Poincaré short-axis SD, ms. SD1² = SDSD² / 2.
    public let sd1: Double
    /// Poincaré long-axis SD, ms. SD2² = 2·SDNN² − SD1².
    public let sd2: Double
    /// SD2 / SD1.
    public let sd2OverSD1: Double
    /// HRV triangular index: total NN count divided by the height of the NN histogram
    /// built on 7.8125 ms bins (1/128 s), per the Task Force definition.
    public let triangularIndex: Double

    public static let empty = TimeDomainMetrics(
        nnCount: 0, differenceCount: 0, coveredDuration: 0, meanNN: .nan, medianNN: .nan,
        meanHR: .nan, sdnn: .nan, rmssd: .nan, lnRMSSD: .nan, sdsd: .nan, pnn50: .nan,
        pnn20: .nan, sd1: .nan, sd2: .nan, sd2OverSD1: .nan, triangularIndex: .nan
    )
}

public enum TimeDomain {

    /// Compute time-domain indices over a set of gap-free segments.
    public static func metrics(for segments: [IntervalSegment]) -> TimeDomainMetrics {
        let allNN = segments.flatMap(\.intervals)
        guard allNN.count >= 2 else { return .empty }

        var diffs: [Double] = []
        diffs.reserveCapacity(max(0, allNN.count - segments.count))
        for seg in segments { diffs.append(contentsOf: seg.successiveDifferences) }
        guard !diffs.isEmpty else { return .empty }

        let meanNN = Stats.mean(allNN)
        let sdnn = Stats.sd(allNN)
        let rmssd = (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
        let sdsd = Stats.sd(diffs)
        let sd1 = (sdsd * sdsd / 2).squareRoot()
        let sd2Sq = 2 * sdnn * sdnn - sd1 * sd1
        let sd2 = sd2Sq > 0 ? sd2Sq.squareRoot() : .nan

        return TimeDomainMetrics(
            nnCount: allNN.count,
            differenceCount: diffs.count,
            coveredDuration: allNN.reduce(0, +) / 1000.0,
            meanNN: meanNN,
            medianNN: Stats.median(allNN),
            meanHR: 60_000.0 / meanNN,
            sdnn: sdnn,
            rmssd: rmssd,
            lnRMSSD: log(rmssd),
            sdsd: sdsd,
            pnn50: 100.0 * Double(diffs.filter { abs($0) > 50 }.count) / Double(diffs.count),
            pnn20: 100.0 * Double(diffs.filter { abs($0) > 20 }.count) / Double(diffs.count),
            sd1: sd1,
            sd2: sd2,
            sd2OverSD1: sd2 / sd1,
            triangularIndex: triangularIndex(allNN)
        )
    }

    /// Convenience for a single unbroken interval list.
    public static func metrics(intervalsMS: [Double], start: Date = Date()) -> TimeDomainMetrics {
        metrics(for: [IntervalSegment(start: start, intervals: intervalsMS)])
    }

    /// HRV triangular index on the standard 128 Hz (7.8125 ms) bin grid.
    static func triangularIndex(_ nn: [Double]) -> Double {
        guard !nn.isEmpty else { return .nan }
        let binWidth = 1000.0 / 128.0
        var histogram: [Int: Int] = [:]
        for v in nn { histogram[Int((v / binWidth).rounded(.down)), default: 0] += 1 }
        guard let peak = histogram.values.max(), peak > 0 else { return .nan }
        return Double(nn.count) / Double(peak)
    }
}
