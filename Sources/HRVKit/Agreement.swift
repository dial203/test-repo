import Foundation

/// Agreement and equivalence statistics for method-comparison work.
///
/// Built for the specific shape this data has: **many paired epochs nested within
/// nights, from few subjects.** That nesting is not a detail to be pooled away. Treating
/// 200 epochs from 20 nights as 200 independent observations understates the standard
/// error of the bias by roughly the square root of the epochs per night, which is how a
/// method comparison ends up reporting a confidently wrong limit of agreement. Every
/// statistic here is available in a clustered form, and the clustered form is the default.
///
/// - Bland JM, Altman DG. *Statistical methods for assessing agreement between two methods
///   of clinical measurement.* Lancet 1986;327:307–310. https://doi.org/10.1016/S0140-6736(86)90837-8
/// - Bland JM, Altman DG. *Measuring agreement in method comparison studies.*
///   Stat Methods Med Res 1999;8:135–160. https://doi.org/10.1177/096228029900800204
/// - Bland JM, Altman DG. *Agreement between methods of measurement with multiple
///   observations per individual.* J Biopharm Stat 2007;17:571–582.
///   https://doi.org/10.1080/10543400701329422
/// - Lin LI. *A concordance correlation coefficient to evaluate reproducibility.*
///   Biometrics 1989;45:255–268. https://doi.org/10.2307/2532051

/// One paired observation. `cluster` is the unit of dependence — for overnight data that
/// is the night, not the subject, when a single subject contributes many nights.
public struct PairedObservation: Sendable, Hashable, Codable {
    /// The criterion measurement (chest strap, ECG).
    public let reference: Double
    /// The measurement under test (the watch).
    public let test: Double
    /// Grouping label for observations that are not independent of each other.
    public let cluster: String

    public init(reference: Double, test: Double, cluster: String) {
        self.reference = reference
        self.test = test
        self.cluster = cluster
    }

    public var difference: Double { test - reference }
    public var mean: Double { (test + reference) / 2 }
    public var isUsable: Bool { reference.isFinite && test.isFinite }
}

public struct ConfidenceInterval: Sendable, Hashable, Codable {
    public let lower: Double
    public let upper: Double
    public let level: Double

    public init(lower: Double, upper: Double, level: Double = 0.95) {
        self.lower = lower; self.upper = upper; self.level = level
    }

    public func contains(_ value: Double) -> Bool { value >= lower && value <= upper }
    public func isWithin(_ bound: Double) -> Bool { lower > -bound && upper < bound }
}

public struct BlandAltmanResult: Sendable, Hashable, Codable {
    /// Mean difference, test minus reference. Positive means the watch reads high.
    public let bias: Double
    public let biasCI: ConfidenceInterval
    /// SD of the differences. Under clustering this combines within- and between-cluster
    /// components rather than being the naive pooled SD.
    public let sdOfDifferences: Double
    public let lowerLoA: Double
    public let upperLoA: Double
    public let lowerLoACI: ConfidenceInterval
    public let upperLoACI: ConfidenceInterval

    /// Variance decomposition, present only for a clustered analysis.
    public let withinClusterSD: Double?
    public let betweenClusterSD: Double?

    /// Slope of difference on mean. A slope whose CI excludes zero means the bias depends
    /// on magnitude, so a single pair of limits misrepresents agreement across the range —
    /// the usual remedy is to repeat the analysis on log-transformed values.
    public let proportionalBiasSlope: Double
    public let proportionalBiasP: Double

    public let pairCount: Int
    public let clusterCount: Int

    /// Whether the differences show magnitude-dependent bias at the conventional level.
    public var hasProportionalBias: Bool { proportionalBiasP < 0.05 }
}

/// Bland–Altman on the log scale. Because the limits become multiplicative, they apply
/// across the whole measurement range instead of only near the mean — which is what you
/// want for RMSSD, where the spread of differences reliably grows with magnitude.
public struct RatioAgreementResult: Sendable, Hashable, Codable {
    /// Geometric mean of test/reference. 1.0 is no bias; 1.08 means the watch reads 8% high.
    public let ratioBias: Double
    public let ratioBiasCI: ConfidenceInterval
    /// Multiplicative limits: a value is expected to fall within [ref × lower, ref × upper].
    public let lowerRatioLoA: Double
    public let upperRatioLoA: Double
    public let pairCount: Int
    public let clusterCount: Int
}

public struct ConcordanceResult: Sendable, Hashable, Codable {
    /// Lin's concordance correlation coefficient.
    public let ccc: Double
    public let cccCI: ConfidenceInterval
    /// Pearson r — precision alone.
    public let pearson: Double
    /// Bias correction factor. `ccc = pearson × biasCorrectionFactor`, which separates
    /// "the points are tight" from "the points are on the identity line".
    public let biasCorrectionFactor: Double
}

public struct ErrorMetrics: Sendable, Hashable, Codable {
    public let rmse: Double
    public let mae: Double
    /// Mean absolute percentage error, relative to the reference.
    public let mape: Double
    /// RMSE as a percentage of the reference mean.
    public let cvRMSE: Double
    public let pairCount: Int
}

/// Two one-sided tests against a pre-specified equivalence bound.
///
/// The bound has to come from somewhere defensible — a smallest worthwhile change, a
/// published typical error, a clinically meaningful difference — and be stated before the
/// analysis. A bound chosen after seeing the data is not an equivalence test.
public struct EquivalenceResult: Sendable, Hashable, Codable {
    public let bound: Double
    public let bias: Double
    /// The 90% CI, whose containment within ±bound is exactly the TOST decision at α=0.05.
    public let ci90: ConfidenceInterval
    public let isEquivalent: Bool
    /// Larger of the two one-sided p-values.
    public let pValue: Double
}

public enum Agreement {

    /// Bland–Altman limits of agreement.
    ///
    /// - Parameter clustered: account for multiple observations per cluster via the
    ///   variance decomposition of Bland & Altman (2007). Leave it on unless every
    ///   observation genuinely comes from a different subject-occasion.
    public static func blandAltman(
        _ pairs: [PairedObservation], clustered: Bool = true, level: Double = 0.95
    ) -> BlandAltmanResult? {
        let usable = pairs.filter(\.isUsable)
        guard usable.count >= 3 else { return nil }

        let differences = usable.map(\.difference)
        let means = usable.map(\.mean)
        let clusters = Set(usable.map(\.cluster))
        let n = usable.count
        let k = clusters.count

        let bias: Double
        let sdDiff: Double
        var within: Double?
        var between: Double?
        let biasSE: Double
        let biasDF: Double

        if clustered, k >= 2, k < n {
            let decomposition = varianceComponents(usable)
            bias = decomposition.mean
            within = decomposition.withinSD
            between = decomposition.betweenSD
            sdDiff = (decomposition.withinSD * decomposition.withinSD
                + decomposition.betweenSD * decomposition.betweenSD).squareRoot()
            // The bias is estimated across clusters, so its precision is governed by the
            // number of clusters, not the number of observations.
            biasSE = decomposition.biasSE
            biasDF = Double(k - 1)
        } else {
            bias = Stats.mean(differences)
            sdDiff = Stats.sd(differences)
            biasSE = sdDiff / Double(n).squareRoot()
            biasDF = Double(n - 1)
        }

        let z = Distributions.normalQuantile(1 - (1 - level) / 2)
        let tBias = Distributions.tQuantile(1 - (1 - level) / 2, df: biasDF)
        let lower = bias - z * sdDiff
        let upper = bias + z * sdDiff

        // SE of a limit of agreement, Bland & Altman (1999) eq. 7. Degrees of freedom
        // follow the clustering, so clustered limits carry honestly wider intervals.
        let effectiveN = clustered && k >= 2 ? Double(k) : Double(n)
        let loaSE = sdDiff * (1 / effectiveN + z * z / (2 * (effectiveN - 1))).squareRoot()
        let tLoA = Distributions.tQuantile(1 - (1 - level) / 2, df: max(effectiveN - 1, 1))

        let regression = Stats.linearFit(x: means, y: differences)
        let slopeP = slopePValue(x: means, y: differences, slope: regression.slope)

        return BlandAltmanResult(
            bias: bias,
            biasCI: ConfidenceInterval(
                lower: bias - tBias * biasSE, upper: bias + tBias * biasSE, level: level
            ),
            sdOfDifferences: sdDiff,
            lowerLoA: lower,
            upperLoA: upper,
            lowerLoACI: ConfidenceInterval(
                lower: lower - tLoA * loaSE, upper: lower + tLoA * loaSE, level: level
            ),
            upperLoACI: ConfidenceInterval(
                lower: upper - tLoA * loaSE, upper: upper + tLoA * loaSE, level: level
            ),
            withinClusterSD: within,
            betweenClusterSD: between,
            proportionalBiasSlope: regression.slope,
            proportionalBiasP: slopeP,
            pairCount: n,
            clusterCount: k
        )
    }

    /// Bland–Altman on natural logs, reported back as multiplicative limits.
    public static func ratioAgreement(
        _ pairs: [PairedObservation], clustered: Bool = true, level: Double = 0.95
    ) -> RatioAgreementResult? {
        let logged = pairs.filter { $0.isUsable && $0.reference > 0 && $0.test > 0 }
            .map { PairedObservation(
                reference: log($0.reference), test: log($0.test), cluster: $0.cluster
            ) }
        guard let result = blandAltman(logged, clustered: clustered, level: level) else { return nil }
        return RatioAgreementResult(
            ratioBias: exp(result.bias),
            ratioBiasCI: ConfidenceInterval(
                lower: exp(result.biasCI.lower), upper: exp(result.biasCI.upper), level: level
            ),
            lowerRatioLoA: exp(result.lowerLoA),
            upperRatioLoA: exp(result.upperLoA),
            pairCount: result.pairCount,
            clusterCount: result.clusterCount
        )
    }

    /// Lin's concordance correlation coefficient, with a cluster bootstrap interval.
    ///
    /// The interval is bootstrapped by resampling whole clusters rather than individual
    /// pairs, so it respects the nesting. Lin's closed-form variance assumes independent
    /// observations and would be too narrow here.
    public static func concordance(
        _ pairs: [PairedObservation], level: Double = 0.95,
        bootstrapSamples: Int = 2000, seed: UInt64 = 20260908
    ) -> ConcordanceResult? {
        let usable = pairs.filter(\.isUsable)
        guard usable.count >= 3 else { return nil }

        let point = cccPoint(usable)
        guard point.ccc.isFinite else { return nil }

        let replicates = clusterBootstrap(
            usable, samples: bootstrapSamples, seed: seed
        ) { cccPoint($0).ccc }
        let ci = percentileInterval(replicates, level: level) ?? ConfidenceInterval(
            lower: .nan, upper: .nan, level: level
        )

        return ConcordanceResult(
            ccc: point.ccc, cccCI: ci,
            pearson: point.pearson, biasCorrectionFactor: point.cb
        )
    }

    public static func errorMetrics(_ pairs: [PairedObservation]) -> ErrorMetrics? {
        let usable = pairs.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        let differences = usable.map(\.difference)
        let rmse = (differences.reduce(0) { $0 + $1 * $1 } / Double(usable.count)).squareRoot()
        let referenceMean = Stats.mean(usable.map(\.reference))
        let percentErrors = usable.filter { $0.reference != 0 }
            .map { abs($0.difference / $0.reference) * 100 }
        return ErrorMetrics(
            rmse: rmse,
            mae: Stats.mean(differences.map(abs)),
            mape: percentErrors.isEmpty ? .nan : Stats.mean(percentErrors),
            cvRMSE: referenceMean != 0 ? 100 * rmse / referenceMean : .nan,
            pairCount: usable.count
        )
    }

    /// TOST equivalence against a pre-specified bound, using the clustered SE.
    public static func equivalence(
        _ pairs: [PairedObservation], bound: Double, clustered: Bool = true
    ) -> EquivalenceResult? {
        let usable = pairs.filter(\.isUsable)
        guard usable.count >= 3, bound > 0 else { return nil }

        let clusters = Set(usable.map(\.cluster))
        let bias: Double, se: Double, df: Double
        if clustered, clusters.count >= 2, clusters.count < usable.count {
            let decomposition = varianceComponents(usable)
            bias = decomposition.mean
            se = decomposition.biasSE
            df = Double(clusters.count - 1)
        } else {
            let differences = usable.map(\.difference)
            bias = Stats.mean(differences)
            se = Stats.sd(differences) / Double(usable.count).squareRoot()
            df = Double(usable.count - 1)
        }
        guard se > 0 else { return nil }

        // Both one-sided tests at α; equivalently, the 90% CI inside ±bound.
        let tLower = (bias + bound) / se
        let tUpper = (bias - bound) / se
        let pLower = 1 - Distributions.tCDF(tLower, df: df)   // H0: μ ≤ −bound
        let pUpper = Distributions.tCDF(tUpper, df: df)       // H0: μ ≥ +bound
        let p = max(pLower, pUpper)

        let t90 = Distributions.tQuantile(0.95, df: df)
        let ci = ConfidenceInterval(lower: bias - t90 * se, upper: bias + t90 * se, level: 0.90)

        return EquivalenceResult(
            bound: bound, bias: bias, ci90: ci, isEquivalent: ci.isWithin(bound), pValue: p
        )
    }

    // MARK: - Internals

    struct VarianceComponents {
        let mean: Double
        let withinSD: Double
        let betweenSD: Double
        let biasSE: Double
    }

    /// One-way random-effects decomposition of the differences by cluster, following
    /// Bland & Altman (2007) for the case where the true value varies between clusters.
    static func varianceComponents(_ pairs: [PairedObservation]) -> VarianceComponents {
        let grouped = Dictionary(grouping: pairs, by: \.cluster)
        let clusterMeans = grouped.mapValues { Stats.mean($0.map(\.difference)) }
        let sizes = grouped.mapValues { $0.count }
        let k = grouped.count
        let n = pairs.count

        // Within-cluster mean square.
        var withinSS = 0.0
        for (cluster, members) in grouped {
            let m = clusterMeans[cluster]!
            withinSS += members.reduce(0) { $0 + pow($1.difference - m, 2) }
        }
        let withinDF = max(n - k, 1)
        let msWithin = withinSS / Double(withinDF)

        // Between-cluster mean square, weighted by cluster size.
        let grandMean = pairs.reduce(0) { $0 + $1.difference } / Double(n)
        var betweenSS = 0.0
        for (cluster, m) in clusterMeans {
            betweenSS += Double(sizes[cluster]!) * pow(m - grandMean, 2)
        }
        let msBetween = k > 1 ? betweenSS / Double(k - 1) : 0

        // Bland & Altman (2007): the divisor is the size-corrected cluster count, which
        // reduces to the common size when clusters are balanced.
        let sumSquares = sizes.values.reduce(0) { $0 + $1 * $1 }
        let m0 = k > 1
            ? (Double(n) - Double(sumSquares) / Double(n)) / Double(k - 1)
            : Double(n)
        let betweenVariance = m0 > 0 ? max(0, (msBetween - msWithin) / m0) : 0

        // The bias is a mean over clusters, so its SE comes from the between-cluster
        // spread of cluster means — not from the number of epochs.
        let meanOfClusterMeans = Stats.mean(Array(clusterMeans.values))
        let sdOfClusterMeans = Stats.sd(Array(clusterMeans.values))
        let biasSE = k > 1 ? sdOfClusterMeans / Double(k).squareRoot() : .nan

        return VarianceComponents(
            mean: meanOfClusterMeans,
            withinSD: msWithin.squareRoot(),
            betweenSD: betweenVariance.squareRoot(),
            biasSE: biasSE
        )
    }

    static func cccPoint(_ pairs: [PairedObservation]) -> (ccc: Double, pearson: Double, cb: Double) {
        let x = pairs.map(\.reference), y = pairs.map(\.test)
        let mx = Stats.mean(x), my = Stats.mean(y)
        let n = Double(pairs.count)
        // Lin uses the n-denominator moments.
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in pairs.indices {
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
            sxy += (x[i] - mx) * (y[i] - my)
        }
        sxx /= n; syy /= n; sxy /= n
        let denominator = sxx + syy + (mx - my) * (mx - my)
        guard denominator > 0 else { return (.nan, .nan, .nan) }
        let ccc = 2 * sxy / denominator
        let pearson = (sxx > 0 && syy > 0) ? sxy / (sxx * syy).squareRoot() : .nan
        return (ccc, pearson, pearson.isFinite ? ccc / pearson : .nan)
    }

    /// Resample whole clusters with replacement.
    static func clusterBootstrap(
        _ pairs: [PairedObservation], samples: Int, seed: UInt64,
        statistic: ([PairedObservation]) -> Double
    ) -> [Double] {
        let grouped = Dictionary(grouping: pairs, by: \.cluster)
        let keys = grouped.keys.sorted()
        guard keys.count >= 2 else { return [] }

        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func nextIndex(_ upperBound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(upperBound))
        }

        var out: [Double] = []
        out.reserveCapacity(samples)
        for _ in 0 ..< samples {
            var resampled: [PairedObservation] = []
            resampled.reserveCapacity(pairs.count)
            for _ in keys.indices {
                resampled.append(contentsOf: grouped[keys[nextIndex(keys.count)]]!)
            }
            let value = statistic(resampled)
            if value.isFinite { out.append(value) }
        }
        return out
    }

    static func percentileInterval(_ replicates: [Double], level: Double) -> ConfidenceInterval? {
        guard replicates.count >= 20 else { return nil }
        let alpha = (1 - level) / 2
        return ConfidenceInterval(
            lower: Stats.percentile(replicates, alpha),
            upper: Stats.percentile(replicates, 1 - alpha),
            level: level
        )
    }

    /// Two-tailed p-value for an OLS slope.
    static func slopePValue(x: [Double], y: [Double], slope: Double) -> Double {
        let n = x.count
        guard n > 2, slope.isFinite else { return .nan }
        let mx = Stats.mean(x)
        let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return .nan }
        let fit = Stats.linearFit(x: x, y: y)
        var residualSS = 0.0
        for i in 0 ..< n {
            let predicted = fit.slope * x[i] + fit.intercept
            residualSS += (y[i] - predicted) * (y[i] - predicted)
        }
        let se = (residualSS / Double(n - 2) / sxx).squareRoot()
        guard se > 0 else { return .nan }
        return Distributions.tTwoTailedP(slope / se, df: Double(n - 2))
    }
}
