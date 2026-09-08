import XCTest
@testable import HRVKit

/// The whole criterion-comparison path, from files on disk to the reported statistics,
/// against data whose true bias and clock offset are known.
///
/// Every stage can look plausible while being wrong — a swallowed gap slides the criterion
/// record, an unestimated clock offset pairs the wrong minutes, a wrong unit guess scales
/// everything by 1000. This test injects known values and checks they come back out.
final class EndToEndTests: XCTestCase {

    private let clockOffset: TimeInterval = 37
    private let ratioBias = 1.08

    /// Criterion RR file with absolute timestamps across several nights, and the watch's
    /// 60 s windows drawn from the same signal with a multiplicative RMSSD bias.
    private func makeFiles(nights: Int = 6) -> (referenceCSV: String, testCSV: String) {
        var referenceRows = ["timestamp,RR (ms)"]
        var testRows = ["series_id,series_start_iso,beat_index,t_since_series_start_s,absolute_time_iso,preceded_by_gap,source,device"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")

        for night in 0 ..< nights {
            let base = Date.fixture.addingTimeInterval(Double(night) * 86400)
            // Vary the respiratory amplitude between nights. Real overnight RMSSD moves
            // by tens of percent night to night, and without that spread there is no
            // range of magnitudes over which proportional bias could be detected — the
            // regression of difference on mean would have nothing to work with.
            let amplitude = 25.0 + 45.0 * Double(night) / Double(max(nights - 1, 1))
            let intervals = Synthetic.tachogram(
                beats: 1800, meanNN: 1090, rsaAmplitude: amplitude,
                respirationHz: 0.22, noiseSD: 12, seed: UInt64(500 + night)
            )

            // Criterion: real timestamps, on a clock running `clockOffset` ahead.
            var t: TimeInterval = 0
            for ms in intervals {
                let stamp = base.addingTimeInterval(t + clockOffset)
                referenceRows.append("\(formatter.string(from: stamp)),\(String(format: "%.2f", ms))")
                t += ms / 1000.0
            }

            // Watch: 60 s windows every 12 minutes, successive differences inflated.
            var windowIndex = 0
            var windowStartSeconds: TimeInterval = 180
            while windowStartSeconds + 60 < t - 60 {
                var collected: [Double] = []
                var cursor: TimeInterval = 0
                for ms in intervals {
                    if cursor >= windowStartSeconds, cursor <= windowStartSeconds + 60 {
                        collected.append(ms)
                    }
                    cursor += ms / 1000.0
                    if cursor > windowStartSeconds + 60 { break }
                }
                if collected.count > 20 {
                    let id = String(format: "%04d0000-0000-4000-8000-%012d", night, windowIndex)
                    let windowStart = base.addingTimeInterval(windowStartSeconds)
                    let startISO = formatter.string(from: windowStart)
                    testRows.append("\(id),\(startISO),0,0.000000,\(startISO),0,com.apple.health,Apple Watch")
                    var offset: TimeInterval = 0
                    for (i, ms) in collected.enumerated() {
                        let previous = i == 0 ? ms : collected[i - 1]
                        let inflated = previous + (ms - previous) * ratioBias
                        offset += inflated / 1000.0
                        let stamp = windowStart.addingTimeInterval(offset)
                        testRows.append("\(id),\(startISO),\(i + 1),\(String(format: "%.6f", offset)),\(formatter.string(from: stamp)),0,com.apple.health,Apple Watch")
                    }
                    windowIndex += 1
                }
                windowStartSeconds += 12 * 60
            }
        }
        return (referenceRows.joined(separator: "\n"), testRows.joined(separator: "\n"))
    }

    func testFullPipelineRecoversInjectedBiasAndClockOffset() throws {
        let files = makeFiles(nights: 6)

        // Criterion side: parse, and confirm the inter-night gaps were found rather than
        // swallowed. Six nights means five gaps.
        let imported = try RRImport.parse(text: files.referenceCSV, start: Date.fixture)
        XCTAssertEqual(imported.provenance.detectedUnits, .milliseconds)
        XCTAssertTrue(imported.provenance.usedTimestampsForPlacement)
        XCTAssertEqual(imported.provenance.gapCount, 5)
        XCTAssertGreaterThan(imported.provenance.gapDuration, 5 * 20 * 3600)
        // Criterion RMSSD must span a real range for the ratio contrast to mean anything.

        // Test side: round-trip the beat CSV back into series.
        let testSeries = try BeatsCSV.parse(files.testCSV)
        XCTAssertGreaterThan(testSeries.count, 10)

        var analysis = NightAnalysisConfiguration.standard
        analysis.windowing = .nativeSeries
        analysis.restrictToMainSleepWindow = false
        analysis.excludeLowQualityWindows = false
        let summary = NightAnalyzer.analyze(
            series: testSeries, sleep: nil, nightOf: Date.fixture, configuration: analysis
        )
        XCTAssertEqual(summary.windows.count, testSeries.count)

        let (epochs, report) = EpochAligner.align(
            testWindows: summary.windows,
            reference: [imported.series()],
            testPreprocessing: analysis.preprocessing
        )

        // Clock offset recovered to within the 1 s search resolution.
        XCTAssertEqual(report.clockOffset, clockOffset, accuracy: 2.0)
        XCTAssertGreaterThan(report.offsetConfidence, 0.8)
        XCTAssertEqual(report.preprocessingMatched, true)
        XCTAssertGreaterThan(epochs.count, 10)
        XCTAssertEqual(Set(epochs.map(\.nightOf)).count, 6)

        let pairs = epochs.compactMap { $0.pair(\.rmssd) }

        // A multiplicative bias shows as proportional bias on the absolute scale...
        let referenceValues = pairs.map(\.reference)
        XCTAssertGreaterThan(
            referenceValues.max()! / referenceValues.min()!, 1.5,
            "the simulated nights must differ enough to test magnitude-dependent bias"
        )

        let absolute = Agreement.blandAltman(pairs)!
        XCTAssertGreaterThan(absolute.bias, 0)
        XCTAssertTrue(
            absolute.hasProportionalBias,
            "a multiplicative bias across a wide range must show as proportional bias"
        )
        XCTAssertEqual(absolute.clusterCount, 6)

        // ...and is recovered cleanly on the ratio scale.
        let ratio = Agreement.ratioAgreement(pairs)!
        XCTAssertEqual(ratio.ratioBias, ratioBias, accuracy: 0.03)
        XCTAssertLessThan(ratio.lowerRatioLoA, ratioBias)
        XCTAssertGreaterThan(ratio.upperRatioLoA, ratioBias)

        // The point of CCC: precision is excellent, concordance is not, because the
        // points sit on a line parallel to identity rather than on identity.
        let concordance = Agreement.concordance(pairs, bootstrapSamples: 400)!
        XCTAssertGreaterThan(concordance.pearson, 0.85)
        XCTAssertLessThan(concordance.ccc, concordance.pearson)
    }

    /// Without offset correction the same data pairs the wrong minutes together, and the
    /// analysis silently reports worse agreement. This is the failure the estimator exists
    /// to prevent.
    func testSkippingOffsetEstimationDegradesAgreement() throws {
        let files = makeFiles(nights: 4)
        let imported = try RRImport.parse(text: files.referenceCSV, start: Date.fixture)
        let testSeries = try BeatsCSV.parse(files.testCSV)

        var analysis = NightAnalysisConfiguration.standard
        analysis.windowing = .nativeSeries
        analysis.restrictToMainSleepWindow = false
        analysis.excludeLowQualityWindows = false
        let summary = NightAnalyzer.analyze(
            series: testSeries, sleep: nil, nightOf: Date.fixture, configuration: analysis
        )

        var noOffset = AlignmentConfiguration.standard
        noOffset.estimateClockOffset = false

        let corrected = EpochAligner.align(
            testWindows: summary.windows, reference: [imported.series()]
        )
        let uncorrected = EpochAligner.align(
            testWindows: summary.windows, reference: [imported.series()], configuration: noOffset
        )

        func rmse(_ epochs: [AlignedEpoch]) -> Double {
            let pairs = epochs.compactMap { $0.pair(\.rmssd) }
            return Agreement.errorMetrics(pairs)?.rmse ?? .infinity
        }
        XCTAssertLessThan(rmse(corrected.epochs), rmse(uncorrected.epochs))
    }
}
