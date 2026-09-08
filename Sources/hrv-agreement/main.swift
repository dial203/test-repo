import Foundation
import HRVKit

/// Runs a criterion comparison from exported files.
///
/// Exists so the analysis does not depend on Xcode, a device, or the app compiling: given
/// a beat export from the watch and an RR file from a chest strap, it does the alignment
/// and the agreement statistics and prints something you could put in a methods section.

// MARK: - Argument handling

struct Options {
    var command = "help"
    var testPath: String?
    var referencePath: String?
    var referenceStart: Date?
    var equivalenceBound: Double = 5.0
    var minimumCoverage = 0.90
    var artifactCeiling = 0.05
    var estimateOffset = true
    var referenceUnits: RRImport.Units?
    var pairedOutputPath: String?
    var metric = "rmssd"
}

func parseArguments(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    if let first = arguments.first, !first.hasPrefix("--") {
        options.command = first
        index = 1
    }
    while index < arguments.count {
        let flag = arguments[index]
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        switch flag {
        case "--test", "-t": options.testPath = value()
        case "--reference", "-r": options.referencePath = value()
        case "--reference-start":
            if let raw = value() { options.referenceStart = parseISO(raw) }
        case "--bound":
            if let raw = value(), let parsed = Double(raw) { options.equivalenceBound = parsed }
        case "--min-coverage":
            if let raw = value(), let parsed = Double(raw) { options.minimumCoverage = parsed }
        case "--artifact-ceiling":
            if let raw = value(), let parsed = Double(raw) { options.artifactCeiling = parsed }
        case "--no-clock-offset": options.estimateOffset = false
        case "--reference-units":
            if let raw = value() { options.referenceUnits = RRImport.Units(rawValue: raw) }
        case "--paired-out": options.pairedOutputPath = value()
        case "--metric": if let raw = value() { options.metric = raw }
        default: break
        }
        index += 1
    }
    return options
}

func parseISO(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: raw) { return date }
    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
        fallback.dateFormat = format
        if let date = fallback.date(from: raw) { return date }
    }
    return nil
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("could not read \(path)")
    }
    return text
}

// MARK: - Formatting

func f(_ value: Double, _ decimals: Int = 2) -> String {
    value.isFinite ? String(format: "%.\(decimals)f", value) : "—"
}

func heading(_ text: String) {
    print("")
    print(text)
    print(String(repeating: "─", count: max(text.count, 40)))
}

enum Metrics {
    static let accessors: [String: @Sendable (TimeDomainMetrics) -> Double] = [
        "rmssd": { $0.rmssd },
        "lnrmssd": { $0.lnRMSSD },
        "sdnn": { $0.sdnn },
        "meanhr": { $0.meanHR },
        "pnn50": { $0.pnn50 },
        "meannn": { $0.meanNN },
        "sd1": { $0.sd1 },
    ]
    static var names: String { accessors.keys.sorted().joined(separator: ", ") }
}

// MARK: - describe

func describe(_ options: Options) {
    guard let path = options.referencePath ?? options.testPath else {
        fail("describe needs --reference <rr-file>")
    }
    let text = read(path)

    let series: IBISeries
    if text.lowercased().contains("series_start_iso") {
        guard let parsed = try? BeatsCSV.parse(text) else { fail("could not parse beat CSV") }
        print("Beat CSV: \(parsed.count) series")
        series = parsed[0]
    } else {
        let start = options.referenceStart ?? Date(timeIntervalSince1970: 0)
        do {
            let imported = try RRImport.parse(
                text: text, start: start, units: options.referenceUnits
            )
            heading("File")
            let provenance = imported.provenance
            print("delimiter          \(provenance.delimiter == "\n" ? "(single column)" : provenance.delimiter)")
            print("interval column    \(provenance.intervalColumnName ?? "#\(provenance.intervalColumnIndex)")")
            print("units detected     \(provenance.detectedUnits.rawValue) (median raw value \(f(provenance.medianRawValue, 3)))")
            print("intervals read     \(provenance.rowsRead)")
            print("rows skipped       \(provenance.rowsSkipped)")
            if let timestamp = provenance.timestampColumnName,
               provenance.usedTimestampsForPlacement {
                print("anchored by        \(timestamp) (used to place beats)")
                print("gaps found         \(provenance.gapCount)"
                    + (provenance.gapCount > 0
                        ? " totalling \(f(provenance.gapDuration / 60, 1)) min"
                        : ""))
            } else if options.referenceStart == nil {
                print("anchored by        (none — pass --reference-start for absolute times)")
                print("beat placement     accumulated from intervals; gaps cannot be detected")
            }
            series = imported.series(sourceIdentifier: path, deviceName: nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    let cleaned = Preprocessor.clean(series)
    heading("Preprocessing")
    print("segments           \(cleaned.segments.count)")
    print("NN intervals       \(cleaned.nnCount)")
    print("duration           \(f(cleaned.coveredDuration / 60, 1)) min")
    let report = cleaned.report
    print("corrected          \(f(report.artifactFraction * 100, 2))% "
        + "(ectopic \(report.ectopic), missed \(report.missed), extra \(report.extra), "
        + "long/short \(report.longShort), out of range \(report.rangeRejected))")
    if report.degenerateDispersion {
        print("note               dispersion too low for adaptive correction; skipped")
    }

    let whole = TimeDomain.metrics(for: cleaned.segments)
    heading("Whole record")
    print("mean NN            \(f(whole.meanNN, 1)) ms   (\(f(whole.meanHR, 1)) bpm)")
    print("RMSSD              \(f(whole.rmssd, 1)) ms   (ln \(f(whole.lnRMSSD, 3)))")
    print("SDNN               \(f(whole.sdnn, 1)) ms")
    print("pNN50              \(f(whole.pnn50, 1))%")
    print("SD1 / SD2          \(f(whole.sd1, 1)) / \(f(whole.sd2, 1)) ms")
    print("NN / differences   \(whole.nnCount) / \(whole.differenceCount)")

    // Five-minute windows: what a continuous criterion record can support and a 60 s
    // watch window cannot.
    var config = NightAnalysisConfiguration.standard
    config.windowing = .fixed(seconds: 300, minimumFill: 0.8)
    config.restrictToMainSleepWindow = false
    config.computeFrequencyDomain = true
    let summary = NightAnalyzer.analyze(
        series: [series], sleep: nil, nightOf: series.start, configuration: config
    )
    heading("Five-minute windows (\(summary.windows.count))")
    if summary.windows.isEmpty {
        print("record too short for a 5-minute window")
    } else {
        let values = summary.windows.map(\.timeDomain.rmssd).filter(\.isFinite)
        print("RMSSD median       \(f(Stats.median(values), 1)) ms")
        print("RMSSD range        \(f(values.min() ?? .nan, 1)) – \(f(values.max() ?? .nan, 1)) ms")
        print("between-window CV  \(f(100 * Stats.sd(values) / Stats.mean(values), 1))%")
        if let spectral = summary.windows.compactMap(\.frequencyDomain).first {
            print("HF (first window)  \(f(spectral.hfPower, 0)) ms², peak \(f(spectral.hfPeak, 3)) Hz")
            if !spectral.unresolvedBands.isEmpty {
                print("unresolved bands   \(spectral.unresolvedBands.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - compare

func compare(_ options: Options) {
    guard let testPath = options.testPath else { fail("compare needs --test <beats.csv>") }
    guard let referencePath = options.referencePath else {
        fail("compare needs --reference <rr-file>")
    }

    guard let testSeries = try? BeatsCSV.parse(read(testPath)) else {
        fail("could not parse \(testPath) as a beat CSV")
    }

    let referenceText = read(referencePath)
    let referenceSeries: [IBISeries]
    if referenceText.lowercased().contains("series_start_iso") {
        guard let parsed = try? BeatsCSV.parse(referenceText) else {
            fail("could not parse \(referencePath)")
        }
        referenceSeries = parsed
    } else {
        do {
            let imported = try RRImport.parse(
                text: referenceText,
                start: options.referenceStart ?? Date(timeIntervalSince1970: 0),
                units: options.referenceUnits
            )
            // Absolute time has to come from somewhere. If the file carries timestamps it
            // anchors itself; otherwise the caller must say when the recording started,
            // because aligning to the watch is meaningless without it.
            if !imported.provenance.usedTimestampsForPlacement, options.referenceStart == nil {
                fail("""
                    the reference file has no usable timestamp column, so its absolute \
                    start time is unknown and it cannot be aligned to the watch. Pass \
                    --reference-start with the recording start, e.g. \
                    --reference-start 2026-03-01T23:14:00-05:00
                    """)
            }
            if imported.provenance.gapCount > 0 {
                print("reference: \(imported.provenance.gapCount) gap(s) totalling "
                    + "\(f(imported.provenance.gapDuration / 60, 1)) min, taken from timestamps")
            }
            referenceSeries = [imported.series(sourceIdentifier: referencePath)]
        } catch {
            fail(error.localizedDescription)
        }
    }

    // The watch's windows are native: each series is one discrete measurement, so
    // re-windowing would merge unrelated epochs.
    var analysis = NightAnalysisConfiguration.standard
    analysis.windowing = .nativeSeries
    analysis.restrictToMainSleepWindow = false
    analysis.excludeLowQualityWindows = false
    let testSummary = NightAnalyzer.analyze(
        series: testSeries, sleep: nil, nightOf: testSeries[0].start, configuration: analysis
    )

    var alignment = AlignmentConfiguration.standard
    alignment.minimumCoverage = options.minimumCoverage
    alignment.artifactCeiling = options.artifactCeiling
    alignment.estimateClockOffset = options.estimateOffset

    let (epochs, report) = EpochAligner.align(
        testWindows: testSummary.windows,
        reference: referenceSeries,
        configuration: alignment,
        testPreprocessing: analysis.preprocessing
    )

    heading("Alignment")
    print("test windows       \(testSummary.windows.count)")
    print("matched epochs     \(report.matched)")
    print("no criterion data  \(report.noReferenceData)")
    print("low coverage       \(report.insufficientCoverage)")
    print("artifact excluded  \(report.excludedForArtifacts)")
    print("clock offset       \(f(report.clockOffset, 1)) s "
        + "(peak r = \(f(report.offsetConfidence, 2)))")
    if report.offsetConfidence < 0.5, options.estimateOffset {
        print("  ⚠ offset estimate is weak; alignment may be wrong. Check that the two")
        print("    recordings actually overlap in time before trusting anything below.")
    }
    switch report.preprocessingMatched {
    case .some(true):
        print("preprocessing      identical on both sides")
    case .some(false):
        print("  ⚠ the two sides were preprocessed differently, so the measured")
        print("    difference mixes device with pipeline. Fix this before reporting.")
    case nil:
        print("preprocessing      test-side configuration not declared, unchecked")
    }

    guard epochs.count >= 3 else {
        print("")
        print("Not enough matched epochs for an agreement analysis.")
        exit(epochs.isEmpty ? 1 : 0)
    }

    let nights = Set(epochs.map(\.nightOf)).count
    print("nights             \(nights)")

    guard let accessor = Metrics.accessors[options.metric.lowercased()] else {
        fail("unknown metric '\(options.metric)'. Available: "
            + Metrics.names)
    }
    let pairs = epochs.compactMap { $0.pair(accessor) }

    heading("Paired epochs: \(options.metric) (n = \(pairs.count), \(nights) night(s))")
    print("criterion mean     \(f(Stats.mean(pairs.map(\.reference)), 2))")
    print("test mean          \(f(Stats.mean(pairs.map(\.test)), 2))")

    if let ba = Agreement.blandAltman(pairs, clustered: nights >= 2) {
        heading("Bland–Altman" + (nights >= 2 ? " (clustered by night)" : ""))
        print("bias               \(f(ba.bias)) "
            + "[\(f(ba.biasCI.lower)), \(f(ba.biasCI.upper))]")
        print("SD of differences  \(f(ba.sdOfDifferences))")
        if let within = ba.withinClusterSD, let between = ba.betweenClusterSD {
            print("  within-night     \(f(within))")
            print("  between-night    \(f(between))")
        }
        print("lower LoA          \(f(ba.lowerLoA)) "
            + "[\(f(ba.lowerLoACI.lower)), \(f(ba.lowerLoACI.upper))]")
        print("upper LoA          \(f(ba.upperLoA)) "
            + "[\(f(ba.upperLoACI.lower)), \(f(ba.upperLoACI.upper))]")
        print("proportional bias  slope \(f(ba.proportionalBiasSlope, 4)), p = \(f(ba.proportionalBiasP, 4))")
        if ba.hasProportionalBias {
            print("  ⚠ bias depends on magnitude, so one pair of limits misrepresents")
            print("    agreement across the range. Use the ratio limits below.")
        }
    }

    if let ratio = Agreement.ratioAgreement(pairs, clustered: nights >= 2) {
        heading("Ratio limits (log scale)")
        print("ratio bias         \(f(ratio.ratioBias, 3)) "
            + "[\(f(ratio.ratioBiasCI.lower, 3)), \(f(ratio.ratioBiasCI.upper, 3))]")
        print("ratio LoA          \(f(ratio.lowerRatioLoA, 3)) – \(f(ratio.upperRatioLoA, 3))")
        print("interpretation     test reads \(f((ratio.ratioBias - 1) * 100, 1))% "
            + "vs criterion on average; individual values within "
            + "\(f((ratio.lowerRatioLoA - 1) * 100, 0))% to +\(f((ratio.upperRatioLoA - 1) * 100, 0))%")
    }

    if let ccc = Agreement.concordance(pairs) {
        heading("Concordance")
        print("Lin's CCC          \(f(ccc.ccc, 3)) "
            + "[\(f(ccc.cccCI.lower, 3)), \(f(ccc.cccCI.upper, 3))]  (cluster bootstrap)")
        print("Pearson r          \(f(ccc.pearson, 3))")
        print("bias correction    \(f(ccc.biasCorrectionFactor, 3))")
    }

    if let errors = Agreement.errorMetrics(pairs) {
        heading("Error")
        print("RMSE               \(f(errors.rmse))")
        print("MAE                \(f(errors.mae))")
        print("MAPE               \(f(errors.mape, 1))%")
        print("RMSE / mean        \(f(errors.cvRMSE, 1))%")
    }

    if let equivalence = Agreement.equivalence(
        pairs, bound: options.equivalenceBound, clustered: nights >= 2
    ) {
        heading("Equivalence (TOST, bound ±\(f(options.equivalenceBound)))")
        print("90% CI             [\(f(equivalence.ci90.lower)), \(f(equivalence.ci90.upper))]")
        print("p                  \(f(equivalence.pValue, 4))")
        print("conclusion         \(equivalence.isEquivalent ? "equivalent within the bound" : "NOT equivalent within the bound")")
        if !equivalence.isEquivalent {
            print("  note: this is not the same as a significant difference. A wide")
            print("  interval means the data cannot decide, which with few nights is")
            print("  the usual reason.")
        }
    }

    if nights < 5 {
        heading("Interpretation")
        print("\(nights) night(s) is a feasibility check, not an agreement study. The limits")
        print("above describe these nights; the between-night component is estimated from")
        print("very few clusters, so treat the intervals as indicative and use them to")
        print("power a proper comparison rather than to conclude one.")
    }

    if let path = options.pairedOutputPath {
        var rows = ["night_of,epoch_start_iso,sleep_stage,reference,test,difference,mean,reference_coverage"]
        let formatter = ISO8601DateFormatter()
        for epoch in epochs {
            guard let pair = epoch.pair(accessor) else { continue }
            rows.append([
                epoch.nightOf, formatter.string(from: epoch.start),
                epoch.sleepStage?.rawValue ?? "",
                String(format: "%.6f", pair.reference),
                String(format: "%.6f", pair.test),
                String(format: "%.6f", pair.difference),
                String(format: "%.6f", pair.mean),
                String(format: "%.4f", epoch.referenceCoverage),
            ].joined(separator: ","))
        }
        try? (rows.joined(separator: "\n") + "\n").write(
            toFile: path, atomically: true, encoding: .utf8
        )
        print("")
        print("Paired epochs written to \(path)")
    }
}

// MARK: - Entry

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

switch options.command {
case "describe":
    describe(options)
case "compare":
    compare(options)
default:
    print("""
        hrv-agreement — criterion comparison for overnight HRV

        describe --reference <file> [--reference-start ISO] [--reference-units ms|seconds]
            Parse an RR or beat file, report what was detected, the artifact load, and
            whole-record plus five-minute-window metrics. Run this on a chest-strap export
            first: it confirms the file really contains beat-to-beat intervals before any
            comparison depends on it.

        compare --test <beats.csv> --reference <file> [options]
            Align the watch's windows to the criterion record and report Bland-Altman
            limits (clustered by night), ratio limits, Lin's CCC with a cluster bootstrap
            interval, error metrics and a TOST equivalence test.

            --reference-start ISO     start time, if the reference file has no timestamps
            --reference-units ms|seconds   bypass unit detection
            --metric NAME             \(Metrics.names)
            --bound N                 equivalence bound in the metric's units (default 5)
            --min-coverage F          criterion coverage required per epoch (default 0.9)
            --artifact-ceiling F      per-side artifact limit (default 0.05)
            --no-clock-offset         skip clock-offset estimation
            --paired-out PATH         write the paired epochs as CSV for plotting
        """)
}
