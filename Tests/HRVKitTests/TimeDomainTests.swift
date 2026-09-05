import XCTest
@testable import HRVKit

final class TimeDomainTests: XCTestCase {

    func testRMSSDMatchesHandComputedValue() {
        // NN = [800, 810, 795, 820, 805]
        // diffs = [10, -15, 25, -15]; squares = [100, 225, 625, 225]; mean = 293.75
        let m = TimeDomain.metrics(intervalsMS: [800, 810, 795, 820, 805])
        XCTAssertEqual(m.rmssd, (293.75 as Double).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(m.differenceCount, 4)
        XCTAssertEqual(m.nnCount, 5)
        XCTAssertEqual(m.lnRMSSD, log(m.rmssd), accuracy: 1e-12)
    }

    func testMeanAndSDNNUseSampleDenominator() {
        let nn: [Double] = [800, 810, 795, 820, 805]
        let m = TimeDomain.metrics(intervalsMS: nn)
        XCTAssertEqual(m.meanNN, 806.0, accuracy: 1e-9)
        // Sample SD (n-1) of the above = sqrt(sum((x-806)^2)/4) = sqrt((36+16+121+196+1)/4)
        XCTAssertEqual(m.sdnn, (370.0 / 4.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(m.meanHR, 60_000.0 / 806.0, accuracy: 1e-9)
    }

    func testPNN50AndPNN20() {
        // diffs: 10, -15, 25, -15, 60  -> |d|>50: 1 of 5 = 20%; |d|>20: 2 of 5 = 40%
        let m = TimeDomain.metrics(intervalsMS: [800, 810, 795, 820, 805, 865])
        XCTAssertEqual(m.pnn50, 20.0, accuracy: 1e-9)
        XCTAssertEqual(m.pnn20, 40.0, accuracy: 1e-9)
    }

    /// The core structural guarantee: a successive difference is never taken across a gap.
    func testSuccessiveDifferencesDoNotCrossGaps() {
        let a = IntervalSegment(start: .fixture, intervals: [800, 810, 795])
        let b = IntervalSegment(start: .fixture.addingTimeInterval(600), intervals: [1000, 1010])
        let split = TimeDomain.metrics(for: [a, b])

        // 2 diffs from a, 1 from b = 3 (not the 4 you would get by concatenating).
        XCTAssertEqual(split.differenceCount, 3)
        XCTAssertEqual(split.nnCount, 5)

        let concatenated = TimeDomain.metrics(intervalsMS: [800, 810, 795, 1000, 1010])
        XCTAssertEqual(concatenated.differenceCount, 4)
        // The spliced version is grossly inflated by the 205 ms step across the gap.
        XCTAssertGreaterThan(concatenated.rmssd, split.rmssd * 3)
    }

    func testPoincareIdentities() {
        let nn = Synthetic.tachogram(beats: 300, noiseSD: 15, seed: 3)
        let m = TimeDomain.metrics(intervalsMS: nn)
        // SD1^2 = SDSD^2 / 2
        XCTAssertEqual(m.sd1 * m.sd1, m.sdsd * m.sdsd / 2, accuracy: 1e-8)
        // SD1^2 + SD2^2 = 2 * SDNN^2
        XCTAssertEqual(m.sd1 * m.sd1 + m.sd2 * m.sd2, 2 * m.sdnn * m.sdnn, accuracy: 1e-6)
        XCTAssertEqual(m.sd2OverSD1, m.sd2 / m.sd1, accuracy: 1e-12)
    }

    func testTriangularIndexOnKnownHistogram() {
        // 7.8125 ms bins. 800.0 and 803.0 share bin 102; 900.0 lands in bin 115.
        // 4 intervals, tallest bin holds 3 -> HRV index 4/3.
        let m = TimeDomain.metrics(intervalsMS: [800, 803, 801, 900])
        XCTAssertEqual(m.triangularIndex, 4.0 / 3.0, accuracy: 1e-9)
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertEqual(TimeDomain.metrics(for: []).nnCount, 0)
        XCTAssertEqual(TimeDomain.metrics(intervalsMS: [800]).nnCount, 0)
        XCTAssertTrue(TimeDomain.metrics(intervalsMS: []).rmssd.isNaN)
    }
}

final class StatsTests: XCTestCase {

    func testPercentileMatchesType7() {
        let x: [Double] = [1, 2, 3, 4]
        // R quantile(type=7): 25% -> 1.75, 50% -> 2.5, 75% -> 3.25
        XCTAssertEqual(Stats.percentile(x, 0.25), 1.75, accuracy: 1e-12)
        XCTAssertEqual(Stats.percentile(x, 0.50), 2.50, accuracy: 1e-12)
        XCTAssertEqual(Stats.percentile(x, 0.75), 3.25, accuracy: 1e-12)
        XCTAssertEqual(Stats.quartileDeviation(x), (3.25 - 1.75) / 2, accuracy: 1e-12)
    }

    func testRunningMedianShrinksAtEdges() {
        let x: [Double] = [1, 100, 2, 3, 4]
        let m = Stats.runningMedian(x, window: 3)
        XCTAssertEqual(m, [50.5, 2, 3, 3, 3.5])
    }

    func testTrimmedMeanDropsTails() {
        let x: [Double] = [1, 2, 3, 4, 100]
        XCTAssertEqual(Stats.trimmedMean(x, fraction: 0.2), 3.0, accuracy: 1e-12)
    }

    func testLinearFitRecoversSlope() {
        let x = (0 ..< 50).map(Double.init)
        let y = x.map { 3.5 * $0 - 7.0 }
        let fit = Stats.linearFit(x: x, y: y)
        XCTAssertEqual(fit.slope, 3.5, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, -7.0, accuracy: 1e-9)
    }
}
