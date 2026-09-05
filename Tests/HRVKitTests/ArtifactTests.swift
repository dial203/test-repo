import XCTest
@testable import HRVKit

final class ArtifactTests: XCTestCase {

    /// A realistic clean night-time tachogram: 55 bpm with respiratory modulation and a
    /// little measurement noise.
    private func cleanNN(_ beats: Int = 400, seed: UInt64 = 21) -> [Double] {
        Synthetic.tachogram(beats: beats, meanNN: 1090, rsaAmplitude: 45,
                            respirationHz: 0.22, noiseSD: 12, seed: seed)
    }

    func testMissedBeatIsDetectedAndRMSSDRecovered() {
        let clean = cleanNN()
        let cleanRMSSD = TimeDomain.metrics(intervalsMS: clean).rmssd

        // Drop one detection: two adjacent intervals merge into one ~2× interval.
        var peaks = Synthetic.peaks(from: clean)
        peaks.remove(at: 200)
        let corruptedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: peaks)).rmssd

        let (corrected, report) = AdaptiveArtifactCorrector.correct(peakTimes: peaks)
        let correctedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: corrected)).rmssd

        XCTAssertGreaterThan(report.missed, 0, "a dropped beat should classify as missed")
        XCTAssertGreaterThan(corruptedRMSSD, cleanRMSSD * 1.5,
                             "one missed beat should visibly inflate uncorrected RMSSD")
        XCTAssertEqual(correctedRMSSD, cleanRMSSD, accuracy: cleanRMSSD * 0.10)
    }

    func testExtraBeatIsDetectedAndRMSSDRecovered() {
        let clean = cleanNN(400, seed: 33)
        let cleanRMSSD = TimeDomain.metrics(intervalsMS: clean).rmssd

        // Spurious detection halfway through one cycle.
        var peaks = Synthetic.peaks(from: clean)
        let spurious = (peaks[150] + peaks[151]) / 2
        peaks.insert(spurious, at: 151)
        let corruptedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: peaks)).rmssd

        let (corrected, report) = AdaptiveArtifactCorrector.correct(peakTimes: peaks)
        let correctedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: corrected)).rmssd

        XCTAssertGreaterThan(report.totalCorrected, 0)
        // One spurious detection in 400 beats inflates RMSSD by roughly 30%.
        XCTAssertGreaterThan(corruptedRMSSD, cleanRMSSD * 1.20)
        XCTAssertEqual(correctedRMSSD, cleanRMSSD, accuracy: cleanRMSSD * 0.10)
    }

    func testEctopicBeatIsDetectedAndRMSSDRecovered() {
        let clean = cleanNN(400, seed: 44)
        let cleanRMSSD = TimeDomain.metrics(intervalsMS: clean).rmssd

        // Premature beat followed by a compensatory pause: the classic ectopic signature.
        var peaks = Synthetic.peaks(from: clean)
        peaks[250] -= 0.30
        let corruptedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: peaks)).rmssd

        let (corrected, report) = AdaptiveArtifactCorrector.correct(peakTimes: peaks)
        let correctedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: corrected)).rmssd

        XCTAssertGreaterThan(report.ectopic, 0, "a displaced beat should classify as ectopic")
        // One ectopic beat in 400 inflates RMSSD by roughly 30%.
        XCTAssertGreaterThan(corruptedRMSSD, cleanRMSSD * 1.20)
        XCTAssertEqual(correctedRMSSD, cleanRMSSD, accuracy: cleanRMSSD * 0.10)
    }

    /// The correction must not manufacture changes in clean data — a false-positive rate
    /// high enough to reshape the tachogram would bias every downstream index.
    func testCleanDataIsLeftAlone() {
        let clean = cleanNN(600, seed: 55)
        let peaks = Synthetic.peaks(from: clean)
        let (corrected, report) = AdaptiveArtifactCorrector.correct(peakTimes: peaks)

        XCTAssertLessThan(report.artifactFraction, 0.01,
                          "false-positive rate on clean data should be under 1%")
        let before = TimeDomain.metrics(intervalsMS: clean).rmssd
        let after = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: corrected)).rmssd
        XCTAssertEqual(after, before, accuracy: before * 0.03)
    }

    func testMultipleArtifactsAcrossALongSeries() {
        var clean = cleanNN(1200, seed: 66)
        let cleanRMSSD = TimeDomain.metrics(intervalsMS: clean).rmssd
        var peaks = Synthetic.peaks(from: clean)

        // Six artifacts of mixed type, spread out, applied back-to-front so indices hold.
        peaks[900] += 0.25
        peaks.remove(at: 750)
        peaks.insert((peaks[600] + peaks[601]) / 2, at: 601)
        peaks[450] -= 0.28
        peaks.remove(at: 300)
        peaks[150] += 0.22

        let corruptedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: peaks)).rmssd
        let (corrected, report) = AdaptiveArtifactCorrector.correct(peakTimes: peaks)
        let correctedRMSSD = TimeDomain.metrics(intervalsMS: Synthetic.intervals(fromPeaks: corrected)).rmssd

        XCTAssertGreaterThanOrEqual(report.totalCorrected, 5)
        XCTAssertGreaterThan(corruptedRMSSD, cleanRMSSD * 1.3)
        XCTAssertEqual(correctedRMSSD, cleanRMSSD, accuracy: cleanRMSSD * 0.10)
        clean.removeAll()
    }
}

final class PreprocessingTests: XCTestCase {

    func testGapFlagSplitsSegments() {
        var beats: [Beat] = []
        var t = 0.0
        for i in 0 ..< 40 {
            beats.append(Beat(offset: t, precededByGap: i == 20))
            t += 1.0
        }
        let series = IBISeries(start: .fixture, beats: beats)
        let segments = series.segments()
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, 19)
        XCTAssertEqual(segments[1].count, 19)
    }

    func testOutOfRangeIntervalBreaksTheSegmentInsteadOfBeingInterpolated() {
        // 20 normal intervals, one impossible 2.6 s interval, 20 more.
        var intervals = [Double](repeating: 1000, count: 20)
        intervals.append(2600)
        intervals.append(contentsOf: [Double](repeating: 1000, count: 20))
        let series = IBISeries.fromIntervals(start: .fixture, intervalsMS: intervals)

        var config = PreprocessingConfiguration.rawWithRangeGateOnly
        config.minSegmentLength = 5
        let cleaned = Preprocessor.clean(series, configuration: config)

        XCTAssertEqual(cleaned.segments.count, 2)
        XCTAssertEqual(cleaned.report.rangeRejected, 1)
        XCTAssertTrue(cleaned.segments.allSatisfy { $0.intervals.allSatisfy { $0 == 1000 } })
    }

    func testArtifactFractionIsCarriedNotHidden() {
        var intervals = Synthetic.tachogram(beats: 200, noiseSD: 10, seed: 8)
        for i in stride(from: 10, to: 200, by: 10) { intervals[i] = 2500 }
        let series = IBISeries.fromIntervals(start: .fixture, intervalsMS: intervals)
        let cleaned = Preprocessor.clean(series)
        XCTAssertGreaterThan(cleaned.report.artifactFraction, 0.03)
        XCTAssertTrue(cleaned.isLowQuality)
    }
}

extension ArtifactTests {

    /// A near-metronomic beat train has almost no spread in |dRR|. Every threshold in the
    /// adaptive algorithm is proportional to that spread, so without a guard the detector
    /// labels essentially the whole record as artifact. The guard must catch it and skip
    /// correction rather than reporting a 90%+ artifact rate for a perfectly regular rhythm.
    func testDegenerateDispersionIsDetectedRatherThanFlaggedAsAllArtifact() {
        let deterministic = Synthetic.tachogram(beats: 200, meanNN: 1000,
                                                rsaAmplitude: 30, respirationHz: 0.25, noiseSD: 0)
        let (corrected, report) = AdaptiveArtifactCorrector.correct(
            peakTimes: Synthetic.peaks(from: deterministic))

        XCTAssertTrue(report.degenerateDispersion)
        XCTAssertEqual(report.totalCorrected, 0)
        XCTAssertEqual(report.artifactFraction, 0.0, accuracy: 1e-12)
        // Untouched apart from the round trip through cumulative beat times.
        let out = Synthetic.intervals(fromPeaks: corrected)
        XCTAssertEqual(out.count, deterministic.count)
        for (a, b) in zip(out, deterministic) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testGuardDoesNotFireOnRealisticData() {
        for seed in UInt64(1) ... 20 {
            let nn = Synthetic.tachogram(beats: 400, meanNN: 1090, rsaAmplitude: 45,
                                         respirationHz: 0.22, noiseSD: 12, seed: seed)
            XCTAssertFalse(
                AdaptiveArtifactCorrector.isDispersionDegenerate(
                    peakTimes: Synthetic.peaks(from: nn)),
                "degeneracy guard must not fire on a noisy physiological tachogram (seed \(seed))"
            )
        }
    }
}
