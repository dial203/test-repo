import XCTest
@testable import HRVKit

final class NonlinearTests: XCTestCase {

    /// DFA on uncorrelated noise must return α ≈ 0.5, and on a random walk α ≈ 1.5.
    /// These are the two analytic anchors for the algorithm.
    func testDFAOnWhiteNoiseIsHalf() {
        let x = Synthetic.whiteNoise(4000, sd: 1, seed: 101)
        XCTAssertEqual(Nonlinear.dfa(x, scales: Array(4 ... 16)), 0.5, accuracy: 0.10)
    }

    func testDFAOnRandomWalkIsThreeHalves() {
        let x = Synthetic.randomWalk(4000, sd: 1, seed: 202)
        XCTAssertEqual(Nonlinear.dfa(x, scales: Array(stride(from: 16, through: 64, by: 4))),
                       1.5, accuracy: 0.15)
    }

    func testDFARefusesShortRecords() {
        XCTAssertTrue(Nonlinear.dfa(Synthetic.whiteNoise(150), scales: Array(4 ... 16)).isNaN,
                      "α1 from 150 beats is not a number worth reporting")
    }

    func testSampleEntropyOrdersRegularBelowRandom() {
        let periodic = (0 ..< 1000).map { 1000 + 40 * sin(2 * .pi * Double($0) / 20) }
        let random = Synthetic.whiteNoise(1000, sd: 40, seed: 303).map { 1000 + $0 }
        let sePeriodic = Nonlinear.sampleEntropy(periodic)
        let seRandom = Nonlinear.sampleEntropy(random)
        XCTAssertLessThan(sePeriodic, 0.2, "a clean periodic series is nearly self-predicting")
        XCTAssertGreaterThan(seRandom, 1.5)
        XCTAssertLessThan(sePeriodic, seRandom)
    }

    func testNonlinearMetricsUseTheLongestGapFreeRun() {
        let short = IntervalSegment(start: .fixture, intervals: Array(repeating: 1000, count: 10))
        let long = IntervalSegment(start: .fixture.addingTimeInterval(600),
                                   intervals: Synthetic.tachogram(beats: 1000, noiseSD: 20, seed: 404))
        let m = Nonlinear.metrics(for: [short, long])
        XCTAssertEqual(m.nnCount, 1000)
        XCTAssertTrue(m.dfaAlpha1.isFinite)
    }
}
