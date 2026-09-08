import Foundation

/// Reads back the beat-level CSV this project exports, from either the app
/// (`Export.beatsCSV`) or the study server (`/v1/participants/{code}/beats.csv`).
///
/// Round-tripping matters: the beat export is the artefact a reanalysis starts from, so
/// being able to read it back is what makes "re-run the whole pipeline outside the app" a
/// real claim rather than an aspiration.
public enum BeatsCSV {

    public enum ParseError: LocalizedError {
        case missingColumns([String])
        case noRows

        public var errorDescription: String? {
            switch self {
            case let .missingColumns(names):
                return "Beat CSV is missing required column(s): \(names.joined(separator: ", "))"
            case .noRows:
                return "Beat CSV contained no data rows."
            }
        }
    }

    /// Reconstruct series from a beat CSV. Handles both the app's `series_id` header and
    /// the server's `series_uuid`.
    public static func parse(_ text: String) throws -> [IBISeries] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { throw ParseError.noRows }

        let header = splitCSV(lines[0])
        func column(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let index = header.firstIndex(where: { $0.lowercased() == candidate }) {
                    return index
                }
            }
            return nil
        }

        guard let idIndex = column(["series_id", "series_uuid"]) else {
            throw ParseError.missingColumns(["series_id or series_uuid"])
        }
        guard let startIndex = column(["series_start_iso"]) else {
            throw ParseError.missingColumns(["series_start_iso"])
        }
        guard let offsetIndex = column(["t_since_series_start_s"]) else {
            throw ParseError.missingColumns(["t_since_series_start_s"])
        }
        let gapIndex = column(["preceded_by_gap"])
        let sourceIndex = column(["source"])
        let deviceIndex = column(["device"])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]

        struct Accumulator {
            var start: Date
            var beats: [Beat] = []
            var source: String?
            var device: String?
        }
        var grouped: [String: Accumulator] = [:]
        var order: [String] = []

        for line in lines.dropFirst() {
            let fields = splitCSV(line)
            guard fields.count > max(idIndex, max(startIndex, offsetIndex)) else { continue }
            let id = fields[idIndex]
            guard let start = formatter.date(from: fields[startIndex])
                ?? fallback.date(from: fields[startIndex]),
                let offset = Double(fields[offsetIndex]) else { continue }

            if grouped[id] == nil {
                grouped[id] = Accumulator(
                    start: start,
                    source: sourceIndex.flatMap { $0 < fields.count ? emptyToNil(fields[$0]) : nil },
                    device: deviceIndex.flatMap { $0 < fields.count ? emptyToNil(fields[$0]) : nil }
                )
                order.append(id)
            }
            let gap = gapIndex.map { $0 < fields.count && (fields[$0] == "1" || fields[$0].lowercased() == "true") } ?? false
            grouped[id]?.beats.append(Beat(offset: offset, precededByGap: gap))
        }

        let series = order.compactMap { id -> IBISeries? in
            guard let accumulator = grouped[id], accumulator.beats.count >= 2 else { return nil }
            return IBISeries(
                id: UUID(uuidString: id) ?? UUID(),
                start: accumulator.start,
                beats: accumulator.beats,
                sourceIdentifier: accumulator.source,
                deviceName: accumulator.device
            )
        }
        guard !series.isEmpty else { throw ParseError.noRows }
        return series.sorted { $0.start < $1.start }
    }

    /// Minimal RFC 4180 field splitter: enough to handle the quoted fields the exporter
    /// emits for source identifiers containing commas.
    static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    static func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
