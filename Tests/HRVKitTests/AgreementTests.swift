import XCTest
@testable import HRVKit

final class DistributionsTests: XCTestCase {

    func testNormalQuantileMatchesPublishedValues() {
        XCTAssertEqual(Distributions.normalQuantile(0.975), 1.959963985, accuracy: 1e-7)
        XCTAssertEqual(Distributions.normalQuantile(0.95), 1.644853627, accuracy: 1e-7)
        XCTAssertEqual(Distributions.normalQuantile(0.5), 0.0, accuracy: 1e-9)
        XCTAssertEqual(Distributions.normalQuantile(0.025), -1.959963985, accuracy: 1e-7)
        XCTAssertEqual(Distributions.normalQuantile(0.001), -3.090232306, accuracy: 1e-6)
    }

    /// Two-tailed critical values from any standard t table.
    func testTQuantileMatchesTables() {
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 1), 12.706, accuracy: 0.001)
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 10), 2.228, accuracy: 0.001)
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 30), 2.042, accuracy: 0.001)
        XCTAssertEqual(Distributions.tQuantile(0.95, df: 20), 1.725, accuracy: 0.001)
        // Converges on the normal.
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 100_000), 1.95996, accuracy: 1e-4)
    }

    func testTCDFAndPValuesAreConsistent() {
        for df in [3.0, 10.0, 47.0] {
            let critical = Distributions.tQuantile(0.975, df: df)
            XCTAssertEqual(Distributions.tCDF(critical, df: df), 0.975, accuracy: 1e-6)
            XCTAssertEqual(Distributions.tTwoTailedP(critical, df: df), 0.05, accuracy: 1e-6)
            XCTAssertEqual(Distributions.tCDF(0, df: df), 0.5, accuracy: 1e-9)
        }
    }

    func testLogGammaMatchesKnownValues() {
        XCTAssertEqual(Distributions.logGamma(1), 0.0, accuracy: 1e-10)
        XCTAssertEqual(Distributions.logGamma(0.5), log(Double.pi.squareRoot()), accuracy: 1e-10)
        XCTAssertEqual(Distributions.logGamma(5), log(24.0), accuracy: 1e-10)   // 4!
        XCTAssertEqual(Distributions.logGamma(10), log(362_880.0), accuracy: 1e-9) // 9!
    }

    func testIncompleteBetaEndpointsAndSymmetry() {
        XCTAssertEqual(Distributions.incompleteBeta(a: 2, b: 3, x: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(Distributions.incompleteBeta(a: 2, b: 3, x: 1), 1.0, accuracy: 1e-12)
        // I_x(a,b) = 1 - I_{1-x}(b,a)
        for x in [0.15, 0.4, 0.62, 0.9] {
            XCTAssertEqual(
                Distributions.incompleteBeta(a: 2.5, b: 4.5, x: x),
                1 - Distributions.incompleteBeta(a: 4.5, b: 2.5, x: 1 - x),
                accuracy: 1e-10
            )
        }
    }
}

final class BlandAltmanTests: XCTestCase {

    /// Hand-computable case: differences are exactly [2, 4, 6, 8, 10].
    func testUnclusteredBiasAndLimitsAreHandComputable() {
        let pairs = (0 ..< 5).map { i in
            PairedObservation(
                reference: 50.0, test: 50.0 + Double(2 * (i + 1)), cluster: "n\(i)"
            )
        }
        // Every cluster has one observation, so the clustered path cannot apply and the
        // naive formulas are used.
        let result = Agreement.blandAltman(pairs, clustered: true)!
        XCTAssertEqual(result.bias, 6.0, accuracy: 1e-9)
        let sd = (40.0 / 4.0).squareRoot()   // sample SD of [2,4,6,8,10]
        XCTAssertEqual(result.sdOfDifferences, sd, accuracy: 1e-9)
        let z = Distributions.normalQuantile(0.975)
        XCTAssertEqual(result.lowerLoA, 6.0 - z * sd, accuracy: 1e-7)
        XCTAssertEqual(result.upperLoA, 6.0 + z * sd, accuracy: 1e-7)
        XCTAssertEqual(result.pairCount, 5)
    }

    /// The reason the clustered form is the default.
    ///
    /// 20 nights, 10 epochs each. Bias varies between nights but is near-constant within
    /// one. Pooling the 200 epochs as if independent makes the confidence interval on the
    /// bias far too narrow, because the real information about bias is carried by 20
    /// nights, not 200 correlated epochs.
    func testClusteringWidensTheBiasIntervalItShouldWiden() {
        var rng = SplitMix64(seed: 4242)
        var pairs: [PairedObservation] = []
        for night in 0 ..< 20 {
            let nightBias = 5.0 * rng.gaussian()          // between-night
            for _ in 0 ..< 10 {
                let reference = 45.0 + 8.0 * rng.gaussian()
                let noise = 0.5 * rng.gaussian()          // small within-night
                pairs.append(PairedObservation(
                    reference: reference,
                    test: reference + nightBias + noise,
                    cluster: "night-\(night)"
                ))
            }
        }

        let naive = Agreement.blandAltman(pairs, clustered: false)!
        let clustered = Agreement.blandAltman(pairs, clustered: true)!

        XCTAssertEqual(clustered.clusterCount, 20)
        XCTAssertEqual(clustered.pairCount, 200)

        let naiveWidth = naive.biasCI.upper - naive.biasCI.lower
        let clusteredWidth = clustered.biasCI.upper - clustered.biasCI.lower
        XCTAssertGreaterThan(
            clusteredWidth, naiveWidth * 2.5,
            "pooling correlated epochs should look far more precise than it is"
        )

        // The decomposition should recover the simulated structure: between-night SD ≈ 5,
        // within-night ≈ 0.5.
        XCTAssertEqual(clustered.betweenClusterSD!, 5.0, accuracy: 2.0)
        XCTAssertEqual(clustered.withinClusterSD!, 0.5, accuracy: 0.25)
    }

    func testProportionalBiasIsDetectedWhenPresentAndNotWhenAbsent() {
        // Difference grows with magnitude — the usual pattern for RMSSD.
        var rng = SplitMix64(seed: 7)
        let sloped = (0 ..< 120).map { i -> PairedObservation in
            let reference = 20.0 + Double(i)
            return PairedObservation(
                reference: reference,
                test: reference * 1.20 + 1.0 * rng.gaussian(),
                cluster: "n\(i / 10)"
            )
        }
        let slopedResult = Agreement.blandAltman(sloped)!
        XCTAssertTrue(slopedResult.hasProportionalBias)
        XCTAssertGreaterThan(slopedResult.proportionalBiasSlope, 0.1)

        // Constant offset — no proportional bias.
        var rng2 = SplitMix64(seed: 8)
        let flat = (0 ..< 120).map { i -> PairedObservation in
            let reference = 20.0 + Double(i)
            return PairedObservation(
                reference: reference,
                test: reference + 5.0 + 1.0 * rng2.gaussian(),
                cluster: "n\(i / 10)"
            )
        }
        XCTAssertFalse(Agreement.blandAltman(flat)!.hasProportionalBias)
    }

    /// A constant proportional error should give ratio limits that bracket the ratio
    /// tightly, where absolute limits would widen with magnitude.
    func testRatioAgreementRecoversAMultiplicativeBias() {
        var rng = SplitMix64(seed: 99)
        let pairs = (0 ..< 200).map { i -> PairedObservation in
            let reference = 20.0 + 60.0 * Double(i % 50) / 50.0
            return PairedObservation(
                reference: reference,
                test: reference * 1.10 * exp(0.02 * rng.gaussian()),
                cluster: "n\(i / 10)"
            )
        }
        let ratio = Agreement.ratioAgreement(pairs)!
        XCTAssertEqual(ratio.ratioBias, 1.10, accuracy: 0.02)
        XCTAssertLessThan(ratio.lowerRatioLoA, 1.10)
        XCTAssertGreaterThan(ratio.upperRatioLoA, 1.10)
        // ±2% within-observation noise means limits close to the bias.
        XCTAssertLessThan(ratio.upperRatioLoA - ratio.lowerRatioLoA, 0.25)
    }

    func testTooFewPairsReturnsNil() {
        XCTAssertNil(Agreement.blandAltman([
            PairedObservation(reference: 1, test: 1, cluster: "a")
        ]))
    }

    func testNonFiniteValuesAreDropped() {
        let pairs = [
            PairedObservation(reference: 40, test: 42, cluster: "a"),
            PairedObservation(reference: .nan, test: 42, cluster: "a"),
            PairedObservation(reference: 40, test: .nan, cluster: "b"),
            PairedObservation(reference: 50, test: 52, cluster: "b"),
            PairedObservation(reference: 60, test: 62, cluster: "c"),
        ]
        let result = Agreement.blandAltman(pairs)!
        XCTAssertEqual(result.pairCount, 3)
        XCTAssertEqual(result.bias, 2.0, accuracy: 1e-9)
    }
}

final class ConcordanceTests: XCTestCase {

    func testPerfectAgreementGivesCCCOfOne() {
        let pairs = (0 ..< 40).map {
            PairedObservation(reference: Double($0), test: Double($0), cluster: "n\($0 / 4)")
        }
        let result = Agreement.concordance(pairs, bootstrapSamples: 200)!
        XCTAssertEqual(result.ccc, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.pearson, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.biasCorrectionFactor, 1.0, accuracy: 1e-9)
    }

    /// The property that makes CCC worth reporting over correlation: a perfect linear
    /// relationship with an offset still has r = 1, but CCC falls.
    func testCCCPenalisesOffsetWhereCorrelationDoesNot() {
        let pairs = (0 ..< 40).map {
            PairedObservation(
                reference: Double($0), test: Double($0) + 10, cluster: "n\($0 / 4)"
            )
        }
        let result = Agreement.concordance(pairs, bootstrapSamples: 200)!
        XCTAssertEqual(result.pearson, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(result.ccc, 0.8)
        XCTAssertEqual(result.ccc, result.pearson * result.biasCorrectionFactor, accuracy: 1e-9)
    }

    func testCCCPenalisesScaleShift() {
        let pairs = (1 ... 40).map {
            PairedObservation(
                reference: Double($0), test: Double($0) * 1.5, cluster: "n\($0 / 4)"
            )
        }
        let result = Agreement.concordance(pairs, bootstrapSamples: 200)!
        XCTAssertEqual(result.pearson, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(result.ccc, 0.95)
    }

    func testBootstrapIntervalBracketsThePointEstimate() {
        var rng = SplitMix64(seed: 31337)
        let pairs = (0 ..< 200).map { i -> PairedObservation in
            let reference = 40.0 + 15.0 * rng.gaussian()
            return PairedObservation(
                reference: reference, test: reference + 3.0 * rng.gaussian(), cluster: "n\(i / 10)"
            )
        }
        let result = Agreement.concordance(pairs, bootstrapSamples: 600)!
        XCTAssertTrue(result.cccCI.contains(result.ccc))
        XCTAssertLessThan(result.cccCI.upper, 1.0001)
    }
}

final class EquivalenceTests: XCTestCase {

    func testTightAgreementIsDeclaredEquivalent() {
        var rng = SplitMix64(seed: 11)
        let pairs = (0 ..< 200).map { i -> PairedObservation in
            let reference = 45.0 + 10.0 * rng.gaussian()
            return PairedObservation(
                reference: reference, test: reference + 0.2 * rng.gaussian(), cluster: "n\(i / 10)"
            )
        }
        let result = Agreement.equivalence(pairs, bound: 5.0)!
        XCTAssertTrue(result.isEquivalent)
        XCTAssertLessThan(result.pValue, 0.05)
        XCTAssertTrue(result.ci90.isWithin(5.0))
    }

    func testRealBiasIsNotDeclaredEquivalent() {
        var rng = SplitMix64(seed: 12)
        let pairs = (0 ..< 200).map { i -> PairedObservation in
            let reference = 45.0 + 10.0 * rng.gaussian()
            return PairedObservation(
                reference: reference, test: reference + 8.0 + 1.0 * rng.gaussian(),
                cluster: "n\(i / 10)"
            )
        }
        let result = Agreement.equivalence(pairs, bound: 5.0)!
        XCTAssertFalse(result.isEquivalent)
        XCTAssertGreaterThan(result.pValue, 0.05)
    }

    /// Absence of a significant difference is not equivalence. With few noisy clusters the
    /// interval is too wide to conclude either way, and the test must say so rather than
    /// defaulting to "equivalent".
    func testUnderpoweredDataIsNotDeclaredEquivalent() {
        var rng = SplitMix64(seed: 13)
        let pairs = (0 ..< 9).map { i -> PairedObservation in
            let reference = 45.0 + 10.0 * rng.gaussian()
            return PairedObservation(
                reference: reference, test: reference + 12.0 * rng.gaussian(), cluster: "n\(i / 3)"
            )
        }
        let result = Agreement.equivalence(pairs, bound: 5.0)!
        XCTAssertFalse(result.isEquivalent)
        XCTAssertGreaterThan(result.ci90.upper - result.ci90.lower, 5.0)
    }
}

final class ErrorMetricTests: XCTestCase {

    func testErrorMetricsAreHandComputable() {
        // differences: +3, -4, +5 -> RMSE = sqrt((9+16+25)/3), MAE = 4
        let pairs = [
            PairedObservation(reference: 40, test: 43, cluster: "a"),
            PairedObservation(reference: 50, test: 46, cluster: "b"),
            PairedObservation(reference: 60, test: 65, cluster: "c"),
        ]
        let metrics = Agreement.errorMetrics(pairs)!
        XCTAssertEqual(metrics.rmse, (50.0 / 3.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(metrics.mae, 4.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.mape, (3.0 / 40 + 4.0 / 50 + 5.0 / 60) / 3 * 100, accuracy: 1e-9)
        XCTAssertEqual(metrics.cvRMSE, 100 * metrics.rmse / 50.0, accuracy: 1e-9)
    }
}
