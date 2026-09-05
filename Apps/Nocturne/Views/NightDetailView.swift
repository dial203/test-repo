import SwiftUI
import Charts
import HRVKit

struct NightDetailView: View {
    let night: AnalysedNight
    @State private var selectedWindow: HRVWindow?

    var body: some View {
        List {
            Section("Overnight") {
                LabeledContent("RMSSD (median of windows)", value: value(night.summary.rmssd, "%.1f ms"))
                LabeledContent("SDNN", value: value(night.summary.sdnn, "%.1f ms"))
                LabeledContent("SD1 / SD2", value: "\(value(night.summary.sd1, "%.1f")) / \(value(night.summary.sd2, "%.1f")) ms")
                if let rr = night.context.averageRespiratoryRate {
                    LabeledContent("Respiratory rate", value: String(format: "%.1f /min", rr))
                }
            }

            Section {
                Chart(night.summary.windows) { window in
                    PointMark(
                        x: .value("Time", window.start),
                        y: .value("RMSSD", window.timeDomain.rmssd)
                    )
                    .foregroundStyle(by: .value("Stage", window.sleepStage?.rawValue ?? "unknown"))
                    .symbolSize(window.isLowQuality ? 20 : 60)
                }
                .frame(height: 220)
                .chartYAxisLabel("RMSSD (ms)")
            } header: {
                Text("Per-window RMSSD")
            } footer: {
                Text("Small, faded points exceeded the artifact ceiling and were excluded from the nightly value.")
            }

            Section {
                ForEach(sortedAlternates, id: \.key) { entry in
                    LabeledContent(label(for: entry.key), value: value(entry.value, "%.1f ms"))
                }
            } header: {
                Text("Aggregation rules")
            } footer: {
                Text("""
                    The same night under different rules. These disagree by more than most \
                    people expect, which is why the app exports all of them rather than \
                    committing you to one.
                    """)
            }

            if let sleep = night.summary.sleep {
                Section("Sleep") {
                    LabeledContent("Total sleep", value: duration(sleep.totalSleepTime))
                    LabeledContent("Efficiency", value: value(sleep.sleepEfficiency * 100, "%.0f%%"))
                    LabeledContent("Deep", value: duration(sleep.duration(of: .deep)))
                    LabeledContent("REM", value: duration(sleep.duration(of: .rem)))
                    LabeledContent("Core", value: duration(sleep.duration(of: .core)))
                    LabeledContent("Awake", value: duration(sleep.duration(of: .awake)))
                }
            }

            Section("Windows") {
                ForEach(night.summary.windows) { window in
                    NavigationLink { WindowDetailView(window: window) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.start.formatted(date: .omitted, time: .shortened))
                                Text("\(window.sleepStage?.rawValue ?? "unstaged") · \(window.timeDomain.nnCount) beats")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(value(window.timeDomain.rmssd, "%.0f ms")).monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle(night.summary.nightOf.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sortedAlternates: [(key: String, value: Double)] {
        night.summary.alternates
            .filter { $0.value.isFinite }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    private func label(for key: String) -> String {
        switch key {
        case "rmssd.median": return "Median of all windows"
        case "rmssd.mean": return "Mean of all windows"
        case "rmssd.trimmedMean20": return "20% trimmed mean"
        case "rmssd.deep": return "Deep sleep only"
        case "rmssd.core": return "Core sleep only"
        case "rmssd.rem": return "REM only"
        case "rmssd.first30min": return "First 30 min after onset"
        case "rmssd.first60min": return "First 60 min after onset"
        case "rmssd.first240min": return "First 4 h after onset"
        case "rmssd.last60min": return "Last hour before waking"
        case "lnRMSSD.medianOfLogs": return "Median of ln RMSSD"
        default: return key
        }
    }

    private func value(_ v: Double, _ spec: String) -> String {
        v.isFinite ? String(format: spec, v) : "—"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

struct WindowDetailView: View {
    let window: HRVWindow

    var body: some View {
        List {
            Section("Time domain") {
                LabeledContent("RMSSD", value: value(window.timeDomain.rmssd, "%.1f ms"))
                LabeledContent("SDNN", value: value(window.timeDomain.sdnn, "%.1f ms"))
                LabeledContent("pNN50", value: value(window.timeDomain.pnn50, "%.1f%%"))
                LabeledContent("Mean NN", value: value(window.timeDomain.meanNN, "%.1f ms"))
                LabeledContent("Mean HR", value: value(window.timeDomain.meanHR, "%.0f bpm"))
                LabeledContent("SD1", value: value(window.timeDomain.sd1, "%.1f ms"))
                LabeledContent("SD2", value: value(window.timeDomain.sd2, "%.1f ms"))
                LabeledContent("HRV triangular index", value: value(window.timeDomain.triangularIndex, "%.2f"))
            }

            Section {
                LabeledContent("NN intervals", value: "\(window.timeDomain.nnCount)")
                LabeledContent("Valid successive differences", value: "\(window.timeDomain.differenceCount)")
                LabeledContent("Beats corrected", value: value(window.artifactFraction * 100, "%.1f%%"))
            } header: {
                Text("Counts")
            } footer: {
                Text("""
                    Fewer differences than intervals means the window contained a detection \
                    gap. Differences are never taken across one.
                    """)
            }

            if let fd = window.frequencyDomain {
                Section {
                    LabeledContent("HF power", value: value(fd.hfPower, "%.0f ms²"))
                    LabeledContent("HF peak", value: value(fd.hfPeak, "%.3f Hz"))
                    LabeledContent("LF power", value: value(fd.lfPower, "%.0f ms²"))
                    LabeledContent("LF/HF", value: value(fd.lfhfRatio, "%.2f"))
                } header: {
                    Text("Frequency domain")
                } footer: {
                    if !fd.unresolvedBands.isEmpty {
                        Text("\(fd.unresolvedBands.joined(separator: " and ")) not reported: this window is too short to hold four cycles of the band's lowest frequency.")
                    }
                }
            } else if let refusal = window.spectralRefusal {
                Section("Frequency domain") {
                    Text(explanation(for: refusal)).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(window.start.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func explanation(for refusal: SpectralRefusal) -> String {
        switch refusal {
        case .tooFewIntervals:
            return "Too few intervals in this window for a spectral estimate."
        case .recordTooShortForLowestBand:
            return "This window is shorter than four cycles of 0.15 Hz, so even HF is unresolvable."
        case .tooShortForWelch:
            return "Welch's method needs at least two full segments; this window is shorter than that."
        }
    }

    private func value(_ v: Double, _ spec: String) -> String {
        v.isFinite ? String(format: spec, v) : "—"
    }
}
