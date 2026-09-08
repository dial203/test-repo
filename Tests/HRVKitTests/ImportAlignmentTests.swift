import XCTest
@testable import HRVKit

final class RRImportTests: XCTestCase {

    private let start = Date.fixture

    func testSingleColumnMilliseconds() throws {
        let text = "812\n845\n798\n860\n''833"
            .replacingOccurrences(of: "''", with: "")
        let result = try RRImport.parse(text: text, start: start)
        XCTAssertEqual(result.intervalsMS, [812, 845, 798, 860, 833])
        XCTAssertEqual(result.provenance.detectedUnits, .milliseconds)
        XCTAssertNil(result.provenance.headerRow)
    }

    func testHeaderedCSVWithNamedColumn() throws {
        let text = """
            Sample rate,RR (ms),Extra
            1,812,x
            1,845,x
            1,798,x
            """
        let result = try RRImport.parse(text: text, start: start)
        XCTAssertEqual(result.intervalsMS, [812, 845, 798])
        XCTAssertEqual(result.provenance.intervalColumnName, "RR (ms)")
        XCTAssertEqual(result.provenance.delimiter, ",")
    }

    /// Polar exports in some locales are semicolon-delimited with a decimal comma.
    func testSemicolonDelimitedWithDecimalComma() throws {
        let text = """
            Time;R-R interval
            00:00:01;812,5
            00:00:02;845,0
            00:00:03;798,25
            """
        let result = try RRImport.parse(text: text, start: start)
        XCTAssertEqual(result.provenance.delimiter, ";")
        XCTAssertEqual(result.intervalsMS[0], 812.5, accuracy: 1e-9)
        XCTAssertEqual(result.intervalsMS[2], 798.25, accuracy: 1e-9)
    }

    func testSecondsAreDetectedAndConverted() throws {
        let text = "0.812\n0.845\n0.798\n0.860"
        let result = try RRImport.parse(text: text, start: start)
        XCTAssertEqual(result.provenance.detectedUnits, .seconds)
        XCTAssertEqual(result.intervalsMS[0], 812, accuracy: 1e-6)
    }

    /// The failure mode that matters most: a wrong units guess scales every interval by
    /// 1000 and yields a plausible-looking, entirely wrong RMSSD. Refuse instead.
    func testImplausibleValuesAreRefusedRatherThanGuessed() {
        let text = "45000\n46000\n47000\n45500"
        XCTAssertThrowsError(try RRImport.parse(text: text, start: start)) { error in
            guard case RRImport.ImportError.ambiguousUnits = error as! RRImport.ImportError else {
                return XCTFail("expected ambiguousUnits, got \(error)")
            }
        }
    }

    func testExplicitUnitsBypassDetection() throws {
        // 0.812 would be read as seconds; force milliseconds and it stays as given.
        let result = try RRImport.parse(text: "0.812\n0.845\n0.798", start: start, units: .milliseconds)
        XCTAssertEqual(result.intervalsMS[0], 0.812, accuracy: 1e-9)
    }

    func testTimestampColumnAnchorsTheSeries() throws {
        let text = """
            timestamp,rr_ms
            2026-03-01T23:30:00Z,812
            2026-03-01T23:30:01Z,845
            2026-03-01T23:30:02Z,798
            """
        let result = try RRImport.parse(text: text, start: start)
        XCTAssertNotEqual(result.start, start, "a file carrying timestamps should override the fallback")
        XCTAssertEqual(
            result.start.timeIntervalSince1970,
            Date(timeIntervalSince1970: 1_772_407_800).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(result.provenance.timestampColumnName, "timestamp")
    }

    func testMalformedRowsAreSkippedAndCounted() throws {
        let text = """
            rr
            812
            not-a-number
            845

            798
            -5
            """
        let result = try RRImport.parse(text: text, start: start)
        XCTAssertEqual(result.intervalsMS, [812, 845, 798])
        XCTAssertEqual(result.provenance.rowsSkipped, 2)   // the text row and the negative
    }

    func testTooFewIntervalsThrows() {
        XCTAssertThrowsError(try RRImport.parse(text: "812", start: start))
        XCTAssertThrowsError(try RRImport.parse(text: "", start: start))
    }

    /// End to end: a parsed file must produce the same RMSSD as the intervals it contains.
    func testParsedSeriesRoundTripsToTheExpectedRMSSD() throws {
        let intervals = Synthetic.tachogram(beats: 300, meanNN: 1090, rsaAmplitude: 45,
                                            respirationHz: 0.22, noiseSD: 12, seed: 5)
        let text = intervals.map { String(format: "%.3f", $0) }.joined(separator: "\n")
        let imported = try RRImport.parse(text: text, start: start)
        XCTAssertEqual(imported.intervalsMS.count, intervals.count)

        let expected = TimeDomain.metrics(intervalsMS: intervals).rmssd
        let actual = TimeDomain.metrics(
            for: imported.series().segments(minSegmentLength: 2)
        ).rmssd
        XCTAssertEqual(actual, expected, accuracy: expected * 1e-4)
    }
}

final class EpochAlignmentTests: XCTestCase {

    /// A continuous criterion night, and watch windows sampled from the same underlying
    /// signal at scattered times.
    private func scenario(
        clockOffset: TimeInterval = 0,
        windowCount: Int = 12,
        gapMinutes: Double = 30
    ) -> (windows: [HRVWindow], reference: [IBISeries]) {
        let onset = Date.fixture
        // 6 hours of continuous beats at ~55 bpm.
        let referenceIntervals = Synthetic.tachogram(
            beats: 6 * 3600 / 1, meanNN: 1090, rsaAmplitude: 45,
            respirationHz: 0.22, noiseSD: 12, seed: 77
        )
        let reference = IBISeries.fromIntervals(
            start: onset.addingTimeInterval(clockOffset),
            intervalsMS: referenceIntervals,
            sourceIdentifier: "polar-h10"
        )

        // Watch windows: 60 s epochs every `gapMinutes`, computed from the same beats so
        // the two sides genuinely measure the same thing.
        //
        // Built from the *preprocessed* criterion, because that is what the real pipeline
        // compares: NightAnalyzer cleans the watch's beats and EpochAligner cleans the
        // criterion's. Building the windows from raw beats instead would make the test
        // measure the preprocessing rather than the alignment.
        let referenceSegments = Preprocessor
            .clean(reference, configuration: AlignmentConfiguration.standard.preprocessing)
            .segments
        var windows: [HRVWindow] = []
        for i in 0 ..< windowCount {
            let windowStart = onset.addingTimeInterval(Double(i) * gapMinutes * 60 + 120)
            let windowEnd = windowStart.addingTimeInterval(60)
            let extracted = EpochAligner.extract(
                referenceSegments,
                from: windowStart.addingTimeInterval(clockOffset),
                to: windowEnd.addingTimeInterval(clockOffset)
            )
            guard !extracted.isEmpty else { continue }
            windows.append(HRVWindow(
                id: UUID(), start: windowStart, end: windowEnd,
                sleepStage: .core,
                timeDomain: TimeDomain.metrics(for: extracted),
                frequencyDomain: nil, spectralRefusal: nil,
                artifactFraction: 0.0, isLowQuality: false,
                sourceSeriesID: UUID()
            ))
        }
        return (windows, [reference])
    }

    func testAlignedEpochsMatchWhenClocksAgree() {
        let (windows, reference) = scenario()
        var config = AlignmentConfiguration.standard
        config.estimateClockOffset = false
        let (epochs, report) = EpochAligner.align(
            testWindows: windows, reference: reference, configuration: config
        )

        XCTAssertEqual(epochs.count, windows.count)
        XCTAssertEqual(report.matched, windows.count)
        XCTAssertEqual(report.noReferenceData, 0)

        // Both sides were computed from the same beats over the same interval, so RMSSD
        // should agree to within rounding.
        for epoch in epochs {
            XCTAssertEqual(
                epoch.test.rmssd, epoch.reference.rmssd, accuracy: 0.5,
                "aligned epochs should recover the criterion value"
            )
            XCTAssertGreaterThan(epoch.referenceCoverage, 0.9)
        }
    }

    /// The point of estimating the offset: a 45 s clock difference silently pairs each
    /// watch window against the wrong minute of the criterion record.
    func testClockOffsetIsEstimatedAndCorrected() {
        let offset: TimeInterval = 45
        let (windows, reference) = scenario(clockOffset: offset, windowCount: 20, gapMinutes: 15)

        var uncorrected = AlignmentConfiguration.standard
        uncorrected.estimateClockOffset = false
        let naive = EpochAligner.align(
            testWindows: windows, reference: reference, configuration: uncorrected
        )

        let corrected = EpochAligner.align(
            testWindows: windows, reference: reference, configuration: .standard
        )

        XCTAssertEqual(corrected.report.clockOffset, offset, accuracy: 5.0)
        XCTAssertGreaterThan(corrected.report.offsetConfidence, 0.5)

        // With the offset applied, paired RMSSD agrees far better than without.
        func meanAbsoluteDifference(_ epochs: [AlignedEpoch]) -> Double {
            let differences = epochs.compactMap { epoch -> Double? in
                guard epoch.test.rmssd.isFinite, epoch.reference.rmssd.isFinite else { return nil }
                return abs(epoch.test.rmssd - epoch.reference.rmssd)
            }
            return differences.isEmpty ? .infinity : Stats.mean(differences)
        }
        XCTAssertLessThan(
            meanAbsoluteDifference(corrected.epochs),
            meanAbsoluteDifference(naive.epochs),
            "correcting the clock offset must improve agreement, not worsen it"
        )
    }

    func testWindowsWithNoCriterionDataAreReportedNotSilentlyDropped() {
        let (windows, reference) = scenario(windowCount: 6)
        // A window a week later has no matching criterion data.
        var extended = windows
        let orphanStart = Date.fixture.addingTimeInterval(7 * 86400)
        extended.append(HRVWindow(
            id: UUID(), start: orphanStart, end: orphanStart.addingTimeInterval(60),
            sleepStage: .deep,
            timeDomain: TimeDomain.metrics(intervalsMS: Synthetic.tachogram(beats: 55)),
            frequencyDomain: nil, spectralRefusal: nil,
            artifactFraction: 0.0, isLowQuality: false, sourceSeriesID: UUID()
        ))

        var config = AlignmentConfiguration.standard
        config.estimateClockOffset = false
        let (epochs, report) = EpochAligner.align(
            testWindows: extended, reference: reference, configuration: config
        )
        XCTAssertEqual(epochs.count, windows.count)
        XCTAssertEqual(report.noReferenceData, 1)
    }

    func testPartiallyCoveredEpochsAreExcluded() {
        let onset = Date.fixture
        // Criterion record stops 30 s into the watch's 60 s window.
        let reference = IBISeries.fromIntervals(
            start: onset, intervalsMS: Array(repeating: 1000, count: 30),
            sourceIdentifier: "strap"
        )
        let window = HRVWindow(
            id: UUID(), start: onset, end: onset.addingTimeInterval(60),
            sleepStage: nil,
            timeDomain: TimeDomain.metrics(intervalsMS: Array(repeating: 1000, count: 60)),
            frequencyDomain: nil, spectralRefusal: nil,
            artifactFraction: 0.0, isLowQuality: false, sourceSeriesID: UUID()
        )
        var config = AlignmentConfiguration.standard
        config.estimateClockOffset = false
        let (epochs, report) = EpochAligner.align(
            testWindows: [window], reference: [reference], configuration: config
        )
        XCTAssertTrue(epochs.isEmpty)
        XCTAssertEqual(report.insufficientCoverage, 1)
    }

    /// Extraction must take only intervals wholly inside the window, so no successive
    /// difference is computed against a beat outside the epoch.
    func testExtractionTakesOnlyWhollyContainedIntervals() {
        let onset = Date.fixture
        let segment = IntervalSegment(
            start: onset, intervals: Array(repeating: 1000, count: 120)
        )
        let extracted = EpochAligner.extract(
            [segment],
            from: onset.addingTimeInterval(30.5),
            to: onset.addingTimeInterval(60.5)
        )
        let total = extracted.reduce(0) { $0 + $1.count }
        // Beats sit at whole seconds; a 30.5–60.5 s window contains beats 31…60,
        // giving 29 intervals between them.
        XCTAssertEqual(total, 29)
        XCTAssertTrue(extracted.allSatisfy { $0.start >= onset.addingTimeInterval(30.5) })
        XCTAssertTrue(extracted.allSatisfy { $0.end <= onset.addingTimeInterval(60.5) })
    }

    func testEpochsProducePairedObservationsClusteredByNight() {
        let (windows, reference) = scenario(windowCount: 8, gapMinutes: 20)
        var config = AlignmentConfiguration.standard
        config.estimateClockOffset = false
        let (epochs, _) = EpochAligner.align(
            testWindows: windows, reference: reference, configuration: config
        )
        let pairs = epochs.compactMap { $0.pair(\.rmssd) }
        XCTAssertEqual(pairs.count, epochs.count)
        // All within one night, so a single cluster.
        XCTAssertEqual(Set(pairs.map(\.cluster)).count, 1)

        let result = Agreement.blandAltman(pairs, clustered: false)!
        XCTAssertEqual(result.bias, 0.0, accuracy: 1.0)
    }
}

extension EpochAlignmentTests {

    /// A mismatch between the two pipelines confounds device with preprocessing, so the
    /// report has to make it visible rather than leaving it to be discovered in review.
    func testPreprocessingMismatchIsFlagged() {
        let (windows, reference) = scenario(windowCount: 6)
        var config = AlignmentConfiguration.standard
        config.estimateClockOffset = false

        let matched = EpochAligner.align(
            testWindows: windows, reference: reference,
            configuration: config, testPreprocessing: config.preprocessing
        )
        XCTAssertEqual(matched.report.preprocessingMatched, true)

        // Same alignment, but the watch side was analysed with correction disabled.
        let mismatched = EpochAligner.align(
            testWindows: windows, reference: reference,
            configuration: config, testPreprocessing: .rawWithRangeGateOnly
        )
        XCTAssertEqual(mismatched.report.preprocessingMatched, false)

        // Undeclared means unchecked, not "fine".
        let undeclared = EpochAligner.align(
            testWindows: windows, reference: reference, configuration: config
        )
        XCTAssertNil(undeclared.report.preprocessingMatched)
    }
}
