import XCTest
@testable import HRVKit

final class FFTTests: XCTestCase {

    func testFFTMatchesNaiveDFT() {
        let n = 64
        var rng = SplitMix64(seed: 99)
        let x = (0 ..< n).map { _ in rng.gaussian() }
        var re = x, im = [Double](repeating: 0, count: n)
        FFT.forward(real: &re, imag: &im)

        for k in [0, 1, 7, 31, 63] {
            var dr = 0.0, di = 0.0
            for t in 0 ..< n {
                let ang = -2 * Double.pi * Double(k) * Double(t) / Double(n)
                dr += x[t] * cos(ang)
                di += x[t] * sin(ang)
            }
            XCTAssertEqual(re[k], dr, accuracy: 1e-9, "real part at bin \(k)")
            XCTAssertEqual(im[k], di, accuracy: 1e-9, "imag part at bin \(k)")
        }
    }

    func testCubicSplineIsExactOnACubic() {
        let x = (0 ..< 20).map { Double($0) * 0.5 }
        let f: (Double) -> Double = { 2 * $0 * $0 * $0 - 3 * $0 * $0 + $0 - 5 }
        let y = x.map(f)
        // Away from the boundaries the natural spline reproduces a cubic to high accuracy.
        for t in [3.1, 4.25, 5.7, 6.0] {
            XCTAssertEqual(CubicSpline.interpolate(x: x, y: y, at: [t])[0], f(t), accuracy: 1e-3)
        }
    }
}

final class SpectralTests: XCTestCase {

    /// A pure sinusoidal modulation of known amplitude must integrate to A²/2 in the
    /// band that contains it. This is the Parseval check that makes band powers in ms²
    /// mean what a reader assumes they mean.
    func testLombScarglePowerRecoversSineVariance() {
        let amplitude = 30.0                 // ms
        let nn = Synthetic.tachogram(beats: 300, meanNN: 1000, rsaAmplitude: amplitude,
                                     respirationHz: 0.25, noiseSD: 0)
        let seg = IntervalSegment(start: .fixture, intervals: nn)
        guard case let .success(m) = FrequencyDomain.metrics(for: seg, method: .lombScargle()) else {
            return XCTFail("spectral estimate refused")
        }
        let expected = amplitude * amplitude / 2   // 450 ms²
        XCTAssertEqual(m.hfPower, expected, accuracy: expected * 0.15)
        XCTAssertEqual(m.hfPeak, 0.25, accuracy: 0.01)
        // Essentially all the power should be in HF, so LF/HF is small.
        XCTAssertLessThan(m.lfhfRatio, 0.1)
    }

    func testLombScargleTotalPowerApproximatesVariance() {
        let nn = Synthetic.tachogram(beats: 400, rsaAmplitude: 25, noiseSD: 10, seed: 5)
        let seg = IntervalSegment(start: .fixture, intervals: nn)
        guard case let .success(m) = FrequencyDomain.metrics(for: seg, method: .lombScargle()) else {
            return XCTFail("spectral estimate refused")
        }
        // Total power covers VLF+LF+HF, i.e. 0.0033–0.40 Hz, so it recovers most but not
        // all of the variance (white noise leaks above 0.40 Hz).
        let variance = Stats.variance(nn)
        XCTAssertGreaterThan(m.totalPower, variance * 0.55)
        XCTAssertLessThan(m.totalPower, variance * 1.15)
    }

    func testWelchAgreesWithLombScargleOnTheSameSignal() {
        let amplitude = 30.0
        let nn = Synthetic.tachogram(beats: 400, rsaAmplitude: amplitude, respirationHz: 0.25)
        let seg = IntervalSegment(start: .fixture, intervals: nn)
        guard case let .success(ls) = FrequencyDomain.metrics(for: seg, method: .lombScargle()),
              case let .success(welch) = FrequencyDomain.metrics(
                  for: seg, method: .interpolatedWelch(resampleHz: 4, segmentSeconds: 64, overlap: 0.5))
        else { return XCTFail("spectral estimate refused") }

        let expected = amplitude * amplitude / 2
        XCTAssertEqual(welch.hfPower, expected, accuracy: expected * 0.30)
        XCTAssertEqual(welch.hfPeak, 0.25, accuracy: 0.02)
        // The two routes should land within 30% of each other on a clean signal.
        XCTAssertEqual(welch.hfPower / ls.hfPower, 1.0, accuracy: 0.30)
    }

    func testShortRecordIsRefusedRatherThanEstimated() {
        // 15 beats ≈ 15 s: below the interval count floor.
        let seg = IntervalSegment(start: .fixture, intervals: Array(repeating: 1000, count: 15))
        guard case let .failure(reason) = FrequencyDomain.metrics(for: seg) else {
            return XCTFail("a 15-beat record must not yield a spectrum")
        }
        XCTAssertEqual(reason, .tooFewIntervals)
    }

    func testWelchRefusesRecordsShorterThanTwoSegments() {
        // 100 beats ≈ 100 s, but the default Welch segment is 256 s.
        let seg = IntervalSegment(start: .fixture, intervals: Synthetic.tachogram(beats: 100))
        guard case let .failure(reason) = FrequencyDomain.metrics(
            for: seg, method: .interpolatedWelch()) else {
            return XCTFail("Welch must refuse a record shorter than two segments")
        }
        XCTAssertEqual(reason, .tooShortForWelch)
    }
}

extension SpectralTests {

    /// The practical consequence for passively collected Apple Watch data: a 60 s
    /// heartbeat series can support HF, but not LF and certainly not VLF.
    func testSixtySecondWindowResolvesHFOnly() {
        let nn = Synthetic.tachogram(beats: 60, rsaAmplitude: 30, respirationHz: 0.25)
        let seg = IntervalSegment(start: .fixture, intervals: nn)
        guard case let .success(m) = FrequencyDomain.metrics(for: seg) else {
            return XCTFail("a 60 s window should still resolve HF")
        }
        XCTAssertEqual(m.unresolvedBands, ["VLF", "LF"])
        XCTAssertTrue(m.vlfPower.isNaN)
        XCTAssertTrue(m.lfPower.isNaN)
        XCTAssertTrue(m.hfPower.isFinite)
        XCTAssertTrue(m.lfhfRatio.isNaN, "LF/HF must not be reported when LF is unresolvable")
    }
}
