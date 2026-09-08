import XCTest
@testable import HRVKit

final class TransientDiagnosticsTests: XCTestCase {

    /// Hand-computable: 100 differences of 20 ms and one of 600 ms.
    /// Sum of squares = 100·400 + 360000 = 400,000, of which the single transient is 90%.
    func testVarianceShareIsHandComputable() {
        var intervals: [Double] = [1000]
        for i in 1 ... 101 {
            intervals.append(intervals[i - 1] + (i == 101 ? 600 : (i % 2 == 0 ? 20 : -20)))
        }
        let segment = IntervalSegment(start: .fixture, intervals: intervals)
        let diagnostics = TransientDiagnostics.compute(for: [segment])!

        XCTAssertEqual(diagnostics.differenceCount, 101)
        XCTAssertEqual(diagnostics.transientCount, 1)
        XCTAssertEqual(diagnostics.largestDifference, 600, accuracy: 1e-9)
        XCTAssertEqual(diagnostics.varianceShare, 360_000.0 / 400_000.0, accuracy: 1e-9)
        XCTAssertEqual(diagnostics.rmssdExcludingTransients, 20.0, accuracy: 1e-9)
        XCTAssertTrue(diagnostics.isTransientDominated)
    }

    /// A record whose variability is genuinely beat-to-beat is not transient-dominated,
    /// however large its RMSSD.
    func testHighButSmoothVariabilityIsNotFlagged() {
        let intervals = Synthetic.tachogram(beats: 2000, meanNN: 1200, rsaAmplitude: 90,
                                            respirationHz: 0.18, noiseSD: 20, seed: 4242)
        let segment = IntervalSegment(start: .fixture, intervals: intervals)
        let diagnostics = TransientDiagnostics.compute(for: [segment])!

        XCTAssertGreaterThan(diagnostics.rmssd, 40, "this record does have large HRV")
        XCTAssertFalse(
            diagnostics.isTransientDominated,
            "large but smooth variability must not be mistaken for transient dominance"
        )
        XCTAssertEqual(diagnostics.rmssd, diagnostics.rmssdExcludingTransients, accuracy: 1.0)
    }

    /// The pattern found on the real overnight file: a small minority of large events
    /// carrying most of the variance.
    func testSparseTransientsDominateTheVariance() {
        var rng = SplitMix64(seed: 77)
        var intervals: [Double] = []
        var current = 1100.0
        for beat in 0 ..< 3000 {
            current += 15 * rng.gaussian()
            current = max(900, min(1300, current))
            // An arousal-like transient roughly every 60 beats.
            intervals.append(beat % 60 == 0 ? current + 520 : current)
        }
        let segment = IntervalSegment(start: .fixture, intervals: intervals)
        let diagnostics = TransientDiagnostics.compute(for: [segment])!

        XCTAssertLessThan(diagnostics.transientFraction, 0.05)
        XCTAssertGreaterThan(diagnostics.varianceShare, 0.5)
        XCTAssertTrue(diagnostics.isTransientDominated)
        // Excluding them roughly halves the reported value.
        XCTAssertLessThan(diagnostics.rmssdExcludingTransients, diagnostics.rmssd * 0.6)
    }

    func testTransientsAreNotCountedAcrossGaps() {
        let a = IntervalSegment(start: .fixture, intervals: [1000, 1010, 1005])
        let b = IntervalSegment(start: .fixture.addingTimeInterval(600), intervals: [700, 705])
        let diagnostics = TransientDiagnostics.compute(for: [a, b])!
        // 2 differences from a, 1 from b. The 305 ms step across the gap is not one.
        XCTAssertEqual(diagnostics.differenceCount, 3)
        XCTAssertEqual(diagnostics.transientCount, 0)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(TransientDiagnostics.compute(for: []))
    }
}

final class RegimeSplitTests: XCTestCase {

    /// A night in two states, which is what the real recording turned out to be: a quiet
    /// first stretch and a high-variability remainder.
    func testTwoRegimeNightShowsALargeSpread() {
        var intervals: [Double] = []
        // ~40 min at 70 bpm with small variability.
        intervals += Synthetic.tachogram(beats: 1700, meanNN: 857, rsaAmplitude: 12,
                                         respirationHz: 0.25, noiseSD: 6, seed: 1)
        // ~40 min at 52 bpm with large variability.
        intervals += Synthetic.tachogram(beats: 1250, meanNN: 1150, rsaAmplitude: 95,
                                         respirationHz: 0.16, noiseSD: 25, seed: 2)

        let segment = IntervalSegment(start: .fixture, intervals: intervals)
        let result = RegimeSplit.describe([segment])!

        // ~48 min of data yields 9 full five-minute windows.
        XCTAssertGreaterThanOrEqual(result.windows.count, 8)
        XCTAssertGreaterThan(result.rmssdSpread, 3.0, "the two states should be plainly separated")
        XCTAssertGreaterThan(result.coefficientOfVariation, 30)

        // Heart rate should fall and RMSSD rise across the transition.
        let firstHalf = result.windows.prefix(result.windows.count / 3)
        let lastHalf = result.windows.suffix(result.windows.count / 3)
        XCTAssertGreaterThan(Stats.mean(firstHalf.map(\.meanHR)), Stats.mean(lastHalf.map(\.meanHR)))
        XCTAssertLessThan(Stats.mean(firstHalf.map(\.rmssd)), Stats.mean(lastHalf.map(\.rmssd)))
    }

    func testStationaryNightShowsASmallSpread() {
        let intervals = Synthetic.tachogram(beats: 3000, meanNN: 1090, rsaAmplitude: 45,
                                            respirationHz: 0.22, noiseSD: 12, seed: 3)
        let result = RegimeSplit.describe([IntervalSegment(start: .fixture, intervals: intervals)])!
        XCTAssertLessThan(result.rmssdSpread, 1.5)
        XCTAssertLessThan(result.coefficientOfVariation, 15)
    }
}
