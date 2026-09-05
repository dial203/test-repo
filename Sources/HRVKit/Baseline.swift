import Foundation

/// Where tonight sits relative to the individual's own recent history.
///
/// The bands are built from the **smallest worthwhile change** (0.5 × the between-night
/// SD of lnRMSSD), not from a fixed percentage or a population norm. Nothing here is a
/// diagnosis and none of it is validated against an outcome; it is a change-detection
/// heuristic on a single-subject time series.
public enum BaselineStatus: String, Sendable, Codable {
    case belowNormal
    case normal
    case aboveNormal
    /// Fewer nights than `Baseline.minimumNights`.
    case establishingBaseline
}

public struct BaselinePoint: Sendable, Hashable, Codable {
    public let nightOf: Date
    public let lnRMSSD: Double
    public init(nightOf: Date, lnRMSSD: Double) {
        self.nightOf = nightOf; self.lnRMSSD = lnRMSSD
    }
}

public struct BaselineResult: Sendable, Hashable, Codable {
    /// Rolling mean of lnRMSSD over the short window (default 7 nights).
    public let shortTermMean: Double
    /// SD of lnRMSSD over the short window.
    public let shortTermSD: Double
    /// CV of lnRMSSD over the short window, as a percentage of the short-term mean.
    /// Plews et al. use rising CV alongside a falling mean as the pattern of interest.
    public let shortTermCV: Double
    /// Rolling mean over the long window (default 60 nights) — the reference distribution.
    public let longTermMean: Double
    public let longTermSD: Double
    /// Smallest worthwhile change, 0.5 × long-term SD, in lnRMSSD units.
    public let smallestWorthwhileChange: Double
    /// (tonight − long-term mean) / long-term SD.
    public let z: Double
    public let status: BaselineStatus
    /// Nights contributing to the long window.
    public let nightsAvailable: Int
}

public enum Baseline {
    /// Below this many nights the SD estimate is too unstable to band against.
    public static let minimumNights = 14

    public static func evaluate(
        tonight: Double,
        history: [BaselinePoint],
        shortWindow: Int = 7,
        longWindow: Int = 60
    ) -> BaselineResult {
        let sorted = history.filter { $0.lnRMSSD.isFinite }.sorted { $0.nightOf < $1.nightOf }
        let long = Array(sorted.suffix(longWindow)).map(\.lnRMSSD)
        let short = Array(sorted.suffix(shortWindow)).map(\.lnRMSSD)

        let shortMean = Stats.mean(short)
        let shortSD = Stats.sd(short)
        let longMean = Stats.mean(long)
        let longSD = Stats.sd(long)
        let swc = 0.5 * longSD
        let z = longSD > 0 ? (tonight - longMean) / longSD : .nan

        let status: BaselineStatus
        if long.count < minimumNights || !longSD.isFinite || longSD == 0 {
            status = .establishingBaseline
        } else if tonight < longMean - swc {
            status = .belowNormal
        } else if tonight > longMean + swc {
            status = .aboveNormal
        } else {
            status = .normal
        }

        return BaselineResult(
            shortTermMean: shortMean,
            shortTermSD: shortSD,
            shortTermCV: shortMean != 0 ? 100 * shortSD / shortMean : .nan,
            longTermMean: longMean,
            longTermSD: longSD,
            smallestWorthwhileChange: swc,
            z: z,
            status: status,
            nightsAvailable: long.count
        )
    }

    /// Rolling 7-night mean series, the form usually plotted for training monitoring.
    public static func rollingMean(_ history: [BaselinePoint], window: Int = 7) -> [BaselinePoint] {
        let sorted = history.sorted { $0.nightOf < $1.nightOf }
        return sorted.indices.map { i in
            let lo = max(0, i - window + 1)
            let slice = sorted[lo ... i].map(\.lnRMSSD).filter { $0.isFinite }
            return BaselinePoint(nightOf: sorted[i].nightOf, lnRMSSD: Stats.mean(slice))
        }
    }
}
