import XCTest
@testable import HRVKit

final class NightAnalysisTests: XCTestCase {

    /// Build a night that looks like passively collected Apple Watch data: a 60 s
    /// heartbeat series every 20 minutes across an 8 h sleep period.
    private func syntheticNight(
        onset: Date = .fixture,
        hours: Double = 8,
        everyMinutes: Double = 20,
        rmssdDrift: Double = 0
    ) -> (series: [IBISeries], sleep: SleepProfile) {
        var series: [IBISeries] = []
        var t = onset
        let end = onset.addingTimeInterval(hours * 3600)
        var i = 0
        while t < end {
            let amplitude = 45 + rmssdDrift * Double(i)
            let nn = Synthetic.tachogram(beats: 55, meanNN: 1090, rsaAmplitude: amplitude,
                                         respirationHz: 0.22, noiseSD: 10,
                                         seed: UInt64(1000 + i))
            series.append(IBISeries.fromIntervals(start: t, intervalsMS: nn,
                                                  sourceIdentifier: "test"))
            t = t.addingTimeInterval(everyMinutes * 60)
            i += 1
        }

        // Alternating core/deep/REM staging in 30 min blocks.
        var intervals: [SleepInterval] = []
        var s = onset
        let order: [SleepStage] = [.core, .deep, .core, .rem]
        var k = 0
        while s < end {
            let e = min(s.addingTimeInterval(1800), end)
            intervals.append(SleepInterval(stage: order[k % order.count], start: s, end: e))
            s = e; k += 1
        }
        return (series, SleepProfile(intervals: intervals))
    }

    func testNightSummaryAggregatesWindows() {
        let (series, sleep) = syntheticNight()
        let summary = NightAnalyzer.analyze(series: series, sleep: sleep, nightOf: .fixture)

        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.windows.count, 24)          // 8 h / 20 min
        // Not necessarily all 24 survive the 5% artifact ceiling: on a ~55-beat window
        // three corrected beats already exceed it, so the odd window is expected to drop.
        XCTAssertGreaterThanOrEqual(summary.usedWindowCount, 22)
        XCTAssertGreaterThan(summary.coverage, 24 * 55)    // ≈ 60 s per window
        XCTAssertTrue(summary.rmssd.isFinite)
        XCTAssertEqual(summary.lnRMSSD, log(summary.rmssd), accuracy: 1e-12)

        // Median must sit inside the range of the per-window values.
        let perWindow = summary.windows.map(\.timeDomain.rmssd)
        XCTAssertGreaterThanOrEqual(summary.rmssd, perWindow.min()!)
        XCTAssertLessThanOrEqual(summary.rmssd, perWindow.max()!)
    }

    func testWindowsAreStagedFromTheSleepProfile() {
        let (series, sleep) = syntheticNight()
        let summary = NightAnalyzer.analyze(series: series, sleep: sleep, nightOf: .fixture)
        let staged = summary.windows.compactMap(\.sleepStage)
        XCTAssertEqual(staged.count, summary.windows.count)
        XCTAssertTrue(staged.contains(.deep))
        XCTAssertTrue(staged.contains(.rem))
        XCTAssertNotNil(summary.alternates["rmssd.deep"])
        XCTAssertNotNil(summary.alternates["rmssd.first30min"])
    }

    /// Aggregation rule matters. A night with a monotone drift in vagal tone gives
    /// materially different answers depending on which windows you keep — which is
    /// exactly why every rule is exported rather than one being hard-coded.
    func testAggregationRulesDisagreeWhenTheNightDrifts() {
        let (series, sleep) = syntheticNight(rmssdDrift: 3.0)
        let summary = NightAnalyzer.analyze(series: series, sleep: sleep, nightOf: .fixture)
        let first30 = summary.alternates["rmssd.first30min"]!
        let last60 = summary.alternates["rmssd.last60min"]!
        XCTAssertTrue(first30.isFinite && last60.isFinite)
        XCTAssertGreaterThan(last60, first30 * 1.2,
                             "a rising-RSA night should read higher late than early")
    }

    func testAnalysisIsRestrictedToTheMainSleepWindow() {
        var (series, sleep) = syntheticNight(hours: 4)
        // A measurement 90 minutes after final awakening must not be counted.
        let strayStart = sleep.finalAwakening!.addingTimeInterval(90 * 60)
        series.append(IBISeries.fromIntervals(
            start: strayStart,
            intervalsMS: Synthetic.tachogram(beats: 55, meanNN: 800, rsaAmplitude: 10)
        ))
        let summary = NightAnalyzer.analyze(series: series, sleep: sleep, nightOf: .fixture)
        XCTAssertFalse(summary.windows.contains { $0.start >= strayStart })
    }

    func testInsufficientDataIsFlaggedNotFabricated() {
        let single = [IBISeries.fromIntervals(
            start: .fixture, intervalsMS: Synthetic.tachogram(beats: 30))]
        let summary = NightAnalyzer.analyze(series: single, sleep: nil, nightOf: .fixture)
        XCTAssertEqual(summary.quality, .sparse)
        XCTAssertLessThan(summary.usedWindowCount, 3)
    }

    func testEmptyNightIsInsufficient() {
        let summary = NightAnalyzer.analyze(series: [], sleep: nil, nightOf: .fixture)
        XCTAssertEqual(summary.quality, .insufficient)
        XCTAssertTrue(summary.rmssd.isNaN)
    }

    func testFixedWindowingSplitsAContinuousRecording() {
        // One continuous 30 min recording, the shape this app's own watch recorder produces.
        let nn = Synthetic.tachogram(beats: 1650, meanNN: 1090, rsaAmplitude: 45, noiseSD: 10)
        let series = [IBISeries.fromIntervals(start: .fixture, intervalsMS: nn)]
        var config = NightAnalysisConfiguration.standard
        config.windowing = .fixed(seconds: 300, minimumFill: 0.8)
        config.restrictToMainSleepWindow = false
        let summary = NightAnalyzer.analyze(series: series, sleep: nil, nightOf: .fixture,
                                            configuration: config)
        XCTAssertGreaterThanOrEqual(summary.windows.count, 5)
        XCTAssertTrue(summary.windows.allSatisfy { $0.duration <= 301 })
        XCTAssertEqual(summary.quality, .good)
    }
}

final class BaselineTests: XCTestCase {

    private func history(_ values: [Double], from: Date = .fixture) -> [BaselinePoint] {
        values.enumerated().map {
            BaselinePoint(nightOf: from.addingTimeInterval(Double($0.offset) * 86400),
                          lnRMSSD: $0.element)
        }
    }

    func testBaselineNeedsEnoughNights() {
        let r = Baseline.evaluate(tonight: 4.0, history: history(Array(repeating: 4.0, count: 5)))
        XCTAssertEqual(r.status, .establishingBaseline)
    }

    func testSmallestWorthwhileChangeIsHalfTheBetweenNightSD() {
        var rng = SplitMix64(seed: 909)
        let values = (0 ..< 60).map { _ in 4.0 + 0.20 * rng.gaussian() }
        let r = Baseline.evaluate(tonight: 4.0, history: history(values))
        XCTAssertEqual(r.smallestWorthwhileChange, 0.5 * r.longTermSD, accuracy: 1e-12)
        XCTAssertEqual(r.longTermSD, 0.20, accuracy: 0.06)
        XCTAssertEqual(r.status, .normal)
    }

    func testStatusBandsFollowTheSWC() {
        var rng = SplitMix64(seed: 1234)
        let values = (0 ..< 60).map { _ in 4.0 + 0.20 * rng.gaussian() }
        let base = Baseline.evaluate(tonight: 4.0, history: history(values))
        let swc = base.smallestWorthwhileChange

        XCTAssertEqual(Baseline.evaluate(tonight: base.longTermMean - swc * 1.5,
                                         history: history(values)).status, .belowNormal)
        XCTAssertEqual(Baseline.evaluate(tonight: base.longTermMean + swc * 1.5,
                                         history: history(values)).status, .aboveNormal)
        XCTAssertEqual(Baseline.evaluate(tonight: base.longTermMean + swc * 0.4,
                                         history: history(values)).status, .normal)
    }

    func testShortTermCVRisesWithInstability() {
        let stable = history(Array(repeating: 4.0, count: 30))
        var rng = SplitMix64(seed: 77)
        let unstable = history((0 ..< 30).map { _ in 4.0 + 0.5 * rng.gaussian() })
        let a = Baseline.evaluate(tonight: 4.0, history: stable)
        let b = Baseline.evaluate(tonight: 4.0, history: unstable)
        XCTAssertEqual(a.shortTermCV, 0.0, accuracy: 1e-9)
        XCTAssertGreaterThan(b.shortTermCV, 3.0)
    }

    func testRollingMeanSmooths() {
        let values = (0 ..< 20).map { Double($0) }
        let rolled = Baseline.rollingMean(history(values), window: 7)
        XCTAssertEqual(rolled.count, 20)
        XCTAssertEqual(rolled[0].lnRMSSD, 0.0, accuracy: 1e-12)
        XCTAssertEqual(rolled[19].lnRMSSD, (13.0 + 19.0) / 2, accuracy: 1e-12)
    }
}

final class ExportTests: XCTestCase {

    func testBeatsCSVHasOneRowPerBeat() {
        let nn = Synthetic.tachogram(beats: 50)
        let s = IBISeries.fromIntervals(start: .fixture, intervalsMS: nn, sourceIdentifier: "unit,test")
        let csv = Export.beatsCSV([s])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 52)                      // header + 51 beats
        XCTAssertTrue(lines[0].hasPrefix("series_id,"))
        XCTAssertTrue(csv.contains("\"unit,test\""), "commas in source ids must be quoted")
    }

    func testIntervalsCSVReproducesTheAnalysedNN() {
        let nn = Synthetic.tachogram(beats: 100, noiseSD: 8)
        let cleaned = Preprocessor.clean(
            IBISeries.fromIntervals(start: .fixture, intervalsMS: nn),
            configuration: .rawWithRangeGateOnly
        )
        let csv = Export.intervalsCSV([cleaned])
        let rows = csv.split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, cleaned.segments.reduce(0) { $0 + $1.count })
    }

    func testNightsCSVIncludesAlternateAggregations() {
        let nn = Synthetic.tachogram(beats: 55)
        let series = (0 ..< 6).map {
            IBISeries.fromIntervals(start: .fixture.addingTimeInterval(Double($0) * 1200),
                                    intervalsMS: nn)
        }
        let summary = NightAnalyzer.analyze(series: series, sleep: nil, nightOf: .fixture)
        let csv = Export.nightsCSV([summary])
        XCTAssertTrue(csv.contains("alt_rmssd_median"))
        XCTAssertTrue(csv.contains("alt_rmssd_trimmedMean20"))
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
    }

    func testNightSummaryRoundTripsThroughJSON() throws {
        let nn = Synthetic.tachogram(beats: 55)
        let series = (0 ..< 4).map {
            IBISeries.fromIntervals(start: .fixture.addingTimeInterval(Double($0) * 1200),
                                    intervalsMS: nn)
        }
        let summary = NightAnalyzer.analyze(series: series, sleep: nil, nightOf: .fixture)
        let data = try Export.json(summary)
        let back = try Export.decode(NightSummary.self, from: data)
        XCTAssertEqual(back.windows.count, summary.windows.count)
        XCTAssertEqual(back.rmssd, summary.rmssd, accuracy: 1e-9)
    }
}
