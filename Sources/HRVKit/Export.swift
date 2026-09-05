import Foundation

/// Export paths that exist so this app can be used as an instrument rather than only a
/// dashboard: the raw beat times, the corrected NN series, and the per-window indices all
/// come out in a form another package can re-analyse.
public enum Export {

    /// Every beat, with its source series and gap flag. One row per beat.
    /// Columns: series_id, series_start_iso, beat_index, t_since_series_start_s,
    /// absolute_time_iso, preceded_by_gap, source, device
    public static func beatsCSV(_ series: [IBISeries]) -> String {
        var rows = ["series_id,series_start_iso,beat_index,t_since_series_start_s,absolute_time_iso,preceded_by_gap,source,device"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for s in series.sorted(by: { $0.start < $1.start }) {
            let startISO = iso.string(from: s.start)
            for (i, b) in s.beats.enumerated() {
                let abs = iso.string(from: s.start.addingTimeInterval(b.offset))
                rows.append([
                    s.id.uuidString, startISO, String(i),
                    String(format: "%.6f", b.offset), abs,
                    b.precededByGap ? "1" : "0",
                    csvEscape(s.sourceIdentifier ?? ""),
                    csvEscape(s.deviceName ?? "")
                ].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Corrected NN intervals after preprocessing, one row per interval, with the segment
    /// it belongs to so successive-difference statistics can be reproduced exactly.
    /// Columns: series_id, segment_index, interval_index, start_iso, nn_ms
    public static func intervalsCSV(_ cleaned: [CleanedSeries]) -> String {
        var rows = ["series_id,segment_index,interval_index,start_iso,nn_ms"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for c in cleaned {
            for (si, seg) in c.segments.enumerated() {
                var t = seg.start
                for (ii, ms) in seg.intervals.enumerated() {
                    rows.append([
                        c.sourceID.uuidString, String(si), String(ii),
                        iso.string(from: t), String(format: "%.3f", ms)
                    ].joined(separator: ","))
                    t = t.addingTimeInterval(ms / 1000.0)
                }
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Per-window indices. One row per analysis window.
    public static func windowsCSV(_ nights: [NightSummary]) -> String {
        var rows = ["night_of,window_start_iso,window_end_iso,duration_s,sleep_stage,nn_count,diff_count,mean_nn_ms,sdnn_ms,rmssd_ms,ln_rmssd,pnn50,pnn20,sd1_ms,sd2_ms,mean_hr_bpm,artifact_fraction,low_quality,lf_ms2,hf_ms2,lf_hf,source_series_id"]
        let iso = ISO8601DateFormatter()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        for night in nights.sorted(by: { $0.nightOf < $1.nightOf }) {
            for w in night.windows {
                let td = w.timeDomain
                rows.append([
                    day.string(from: night.nightOf),
                    iso.string(from: w.start), iso.string(from: w.end),
                    fmt(w.duration), w.sleepStage?.rawValue ?? "",
                    String(td.nnCount), String(td.differenceCount),
                    fmt(td.meanNN), fmt(td.sdnn), fmt(td.rmssd), fmt(td.lnRMSSD),
                    fmt(td.pnn50), fmt(td.pnn20), fmt(td.sd1), fmt(td.sd2), fmt(td.meanHR),
                    fmt(w.artifactFraction), w.isLowQuality ? "1" : "0",
                    fmt(w.frequencyDomain?.lfPower), fmt(w.frequencyDomain?.hfPower),
                    fmt(w.frequencyDomain?.lfhfRatio),
                    w.sourceSeriesID.uuidString
                ].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// One row per night.
    public static func nightsCSV(_ nights: [NightSummary]) -> String {
        var keys = Set<String>()
        for n in nights { keys.formUnion(n.alternates.keys) }
        let altKeys = keys.sorted()
        var header = "night_of,quality,windows_used,coverage_s,artifact_fraction,rmssd_ms,ln_rmssd,sdnn_ms,mean_hr_bpm,min_hr_bpm,pnn50,sd1_ms,sd2_ms,total_sleep_time_s,sleep_efficiency,deep_s,rem_s,core_s"
        header += altKeys.isEmpty ? "" : "," + altKeys.map { "alt_" + $0.replacingOccurrences(of: ".", with: "_") }.joined(separator: ",")
        var rows = [header]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        for n in nights.sorted(by: { $0.nightOf < $1.nightOf }) {
            var cols = [
                day.string(from: n.nightOf), n.quality.rawValue,
                String(n.usedWindowCount), fmt(n.coverage), fmt(n.artifactFraction),
                fmt(n.rmssd), fmt(n.lnRMSSD), fmt(n.sdnn), fmt(n.meanHR), fmt(n.minHR),
                fmt(n.pnn50), fmt(n.sd1), fmt(n.sd2),
                fmt(n.sleep?.totalSleepTime), fmt(n.sleep?.sleepEfficiency),
                fmt(n.sleep?.duration(of: .deep)), fmt(n.sleep?.duration(of: .rem)),
                fmt(n.sleep?.duration(of: .core))
            ]
            cols += altKeys.map { fmt(n.alternates[$0]) }
            rows.append(cols.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// JSON encoder configured for HRV data. Non-finite values are written as the
    /// strings `"NaN"` / `"Infinity"` rather than throwing: an unresolvable band or an
    /// empty night legitimately has no number, and silently dropping the field would be
    /// worse than naming it.
    public static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        enc.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return enc
    }()

    public static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return dec
    }()

    public static func json<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    static func fmt(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.6g", v)
    }

    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
