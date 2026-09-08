import Foundation

/// Reads RR/IBI files from the various things that produce them.
///
/// There is no standard format. Polar Flow's HRV export, Polar ProTrainer text files,
/// Kubios exports, HRV Logger, Polar Sensor Logger and EliteHRV all differ in delimiter,
/// header, column order, decimal separator and units. Rather than one parser per tool,
/// this detects the shape and — importantly — **reports what it decided**, because a
/// silent wrong guess about units would scale every interval by 1000 and produce a
/// perfectly plausible-looking, entirely wrong RMSSD.
public struct RRImport: Sendable {

    public enum Units: String, Sendable, Codable {
        case milliseconds
        case seconds
    }

    public enum ImportError: LocalizedError {
        case noNumericColumn
        case ambiguousUnits(median: Double)
        case tooFewIntervals(Int)

        public var errorDescription: String? {
            switch self {
            case .noNumericColumn:
                return "No column of numeric interval values was found."
            case let .ambiguousUnits(median):
                return """
                    Could not tell whether these are milliseconds or seconds: the median \
                    value is \(median), which is not a plausible inter-beat interval in \
                    either unit. Check the file, or pass the units explicitly.
                    """
            case let .tooFewIntervals(count):
                return "Only \(count) intervals found; need at least 2."
            }
        }
    }

    /// What the parser decided, so it can be checked rather than trusted.
    public struct Provenance: Sendable, Codable, Hashable {
        public let delimiter: String
        public let headerRow: String?
        public let intervalColumnIndex: Int
        public let intervalColumnName: String?
        public let detectedUnits: Units
        public let medianRawValue: Double
        public let rowsRead: Int
        public let rowsSkipped: Int
        /// Set when a timestamp column was found and used to anchor the series.
        public let timestampColumnName: String?
        /// Whether per-row timestamps were used to place the beats.
        ///
        /// This is the difference between a file that reconstructs correctly and one that
        /// silently slides. Accumulating intervals assumes the recording is continuous, so
        /// a strap dropout — or several nights concatenated into one file — would be
        /// swallowed: every beat after the gap lands earlier than it really occurred, by
        /// the whole missing duration. When timestamps are present they define where the
        /// discontinuities are, and those become gap markers.
        public let usedTimestampsForPlacement: Bool
        /// Discontinuities found from the timestamps, each becoming a segment break.
        public let gapCount: Int
        /// Total time the gaps account for, seconds.
        public let gapDuration: TimeInterval
    }

    public let intervalsMS: [Double]
    /// Beats with gap markers, ready to become an `IBISeries`.
    public let beats: [Beat]
    public let provenance: Provenance
    /// Start time, either from the file or supplied by the caller.
    public let start: Date

    /// Parse a delimited text file of intervals.
    ///
    /// - Parameters:
    ///   - text: file contents.
    ///   - start: series start. A file carrying its own timestamps overrides this.
    ///   - units: pass explicitly to bypass detection.
    public static func parse(
        text: String, start: Date, units: Units? = nil
    ) throws -> RRImport {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw ImportError.tooFewIntervals(0) }

        let delimiter = detectDelimiter(lines)

        // A header is a first row whose fields are not parseable as numbers.
        var headerRow: String?
        var headerFields: [String] = []
        var bodyStart = 0
        let firstFields = split(lines[0], by: delimiter)
        if firstFields.contains(where: { number(from: $0) == nil }) {
            headerRow = lines[0]
            headerFields = firstFields
            bodyStart = 1
        }

        // Prefer a column whose header names an interval; otherwise the last numeric one.
        var intervalIndex: Int?
        var timestampIndex: Int?
        for (index, field) in headerFields.enumerated() {
            let name = field.lowercased()
            if intervalIndex == nil,
               name.contains("rr") || name.contains("ibi") || name.contains("interval")
                   || name.contains("nn") || name.contains("beat") {
                intervalIndex = index
            }
            if timestampIndex == nil,
               name.contains("time") || name.contains("date") || name.contains("timestamp") {
                timestampIndex = index
            }
        }

        var values: [Double] = []
        // Parallel to `values`; nil where a row carried no parseable timestamp.
        var timestamps: [Date?] = []
        var skipped = 0

        for line in lines[bodyStart...] {
            let fields = split(line, by: delimiter)
            guard !fields.isEmpty else { skipped += 1; continue }

            let index: Int
            if let intervalIndex, intervalIndex < fields.count {
                index = intervalIndex
            } else if let last = fields.lastIndex(where: { number(from: $0) != nil }) {
                index = last
            } else {
                skipped += 1
                continue
            }
            guard let value = number(from: fields[index]), value > 0 else { skipped += 1; continue }
            values.append(value)
            intervalIndex = intervalIndex ?? index

            if let timestampIndex, timestampIndex < fields.count {
                timestamps.append(parseTimestamp(fields[timestampIndex]))
            } else {
                timestamps.append(nil)
            }
        }

        guard values.count >= 2 else { throw ImportError.tooFewIntervals(values.count) }

        let median = Stats.median(values)
        let resolvedUnits: Units
        if let units {
            resolvedUnits = units
        } else if median >= 250, median <= 2500 {
            resolvedUnits = .milliseconds
        } else if median >= 0.25, median <= 2.5 {
            resolvedUnits = .seconds
        } else {
            // 250–2500 ms is 24–240 bpm. Outside that, in either unit, the file is not a
            // series of inter-beat intervals and guessing would be worse than failing.
            throw ImportError.ambiguousUnits(median: median)
        }

        let scale = resolvedUnits == .seconds ? 1000.0 : 1.0
        let intervalsMS = values.map { $0 * scale }

        // Place the beats. Interval *durations* always come from the RR column, which is
        // what the sensor actually measured and is higher precision than a timestamp
        // column that may only be second-resolution. Timestamps are used for the thing
        // intervals cannot tell you: where the recording stopped and restarted.
        let placement = placeBeats(intervalsMS: intervalsMS, timestamps: timestamps)
        let anchor = timestamps.compactMap { $0 }.first ?? start

        return RRImport(
            intervalsMS: intervalsMS,
            beats: placement.beats,
            provenance: Provenance(
                delimiter: delimiter,
                headerRow: headerRow,
                intervalColumnIndex: intervalIndex ?? 0,
                intervalColumnName: intervalIndex.flatMap {
                    $0 < headerFields.count ? headerFields[$0] : nil
                },
                detectedUnits: resolvedUnits,
                medianRawValue: median,
                rowsRead: values.count,
                rowsSkipped: skipped,
                timestampColumnName: timestampIndex.flatMap {
                    $0 < headerFields.count ? headerFields[$0] : nil
                },
                usedTimestampsForPlacement: placement.usedTimestamps,
                gapCount: placement.gapCount,
                gapDuration: placement.gapDuration
            ),
            start: anchor
        )
    }

    /// Seconds by which an observed timestamp gap must exceed the reported interval before
    /// the recording is treated as discontinuous.
    ///
    /// Generous on purpose: real exports often carry whole-second timestamps, so up to a
    /// second of apparent mismatch per beat is just quantisation. A genuine dropout is
    /// seconds to hours, so nothing sits near this threshold in practice.
    public static let gapTolerance: TimeInterval = 2.0

    struct Placement {
        let beats: [Beat]
        let usedTimestamps: Bool
        let gapCount: Int
        let gapDuration: TimeInterval
    }

    static func placeBeats(intervalsMS: [Double], timestamps: [Date?]) -> Placement {
        let haveTimestamps = timestamps.count == intervalsMS.count
            && timestamps.compactMap { $0 }.count >= max(2, intervalsMS.count * 9 / 10)

        var beats: [Beat] = [Beat(offset: 0, precededByGap: false)]
        var offset: TimeInterval = 0
        var gaps = 0
        var gapDuration: TimeInterval = 0

        guard haveTimestamps else {
            for ms in intervalsMS {
                offset += ms / 1000.0
                beats.append(Beat(offset: offset, precededByGap: false))
            }
            return Placement(beats: beats, usedTimestamps: false, gapCount: 0, gapDuration: 0)
        }

        var previousTimestamp = timestamps.compactMap { $0 }.first!
        for (index, ms) in intervalsMS.enumerated() {
            let expected = ms / 1000.0
            var isGap = false
            if let timestamp = timestamps[index] {
                let observed = timestamp.timeIntervalSince(previousTimestamp)
                if observed - expected > gapTolerance {
                    isGap = true
                    gaps += 1
                    gapDuration += observed - expected
                    // Advance by the observed gap so later beats keep their real times.
                    offset += observed
                } else {
                    offset += expected
                }
                previousTimestamp = timestamp
            } else {
                offset += expected
            }
            beats.append(Beat(offset: offset, precededByGap: isGap))
        }
        return Placement(
            beats: beats, usedTimestamps: true, gapCount: gaps, gapDuration: gapDuration
        )
    }

    /// The parsed intervals as an `IBISeries`, ready for the rest of the library.
    public func series(sourceIdentifier: String = "rr-import", deviceName: String? = nil) -> IBISeries {
        IBISeries(
            start: start, beats: beats,
            sourceIdentifier: sourceIdentifier, deviceName: deviceName
        )
    }

    // MARK: - Detection helpers

    static func detectDelimiter(_ lines: [String]) -> String {
        // Score candidates by how consistently they split the first few rows.
        let candidates = [";", ",", "\t", " "]
        var best = ("\n", 0)
        for candidate in candidates {
            let counts = lines.prefix(10).map { $0.components(separatedBy: candidate).count }
            guard let first = counts.first, first > 1,
                  counts.allSatisfy({ $0 == first }) else { continue }
            if first > best.1 { best = (candidate, first) }
        }
        // A single column has no delimiter; "\n" is the sentinel for that.
        return best.1 > 1 ? best.0 : "\n"
    }

    static func split(_ line: String, by delimiter: String) -> [String] {
        guard delimiter != "\n" else { return [line] }
        return line.components(separatedBy: delimiter).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Parse a number, accepting a decimal comma. Ambiguity between a decimal comma and a
    /// thousands separator is resolved by position: European exports write `812,5`, and a
    /// thousands separator would leave three digits after it.
    static func number(from field: String) -> Double? {
        let cleaned = field.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
        guard !cleaned.isEmpty else { return nil }
        if let value = Double(cleaned) { return value }
        if cleaned.contains(","), !cleaned.contains(".") {
            let parts = cleaned.components(separatedBy: ",")
            if parts.count == 2, parts[1].count != 3 {
                return Double(cleaned.replacingOccurrences(of: ",", with: "."))
            }
            if parts.count == 2, parts[1].count == 3 {
                return Double(parts.joined())
            }
        }
        return nil
    }

    static func parseTimestamp(_ field: String) -> Date? {
        let cleaned = field.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: cleaned) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: cleaned) { return date }

        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                       "dd-MM-yyyy HH:mm:ss", "dd/MM/yyyy HH:mm:ss",
                       "yyyy/MM/dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
