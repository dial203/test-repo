import SwiftUI
import HRVKit

struct TonightView: View {
    @Bindable var repository: NightRepository

    var body: some View {
        NavigationStack {
            List {
                if case let .working(message) = repository.status {
                    Section { Label(message, systemImage: "arrow.clockwise").foregroundStyle(.secondary) }
                }
                if case let .failed(message) = repository.status {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }

                if let night = repository.tonight {
                    headline(night)
                    quality(night)
                    if let baseline = repository.currentBaseline { self.baseline(baseline, night: night) }
                    windows(night)
                    comparison(night)
                } else {
                    ContentUnavailableView(
                        "No night analysed yet",
                        systemImage: "moon.zzz",
                        description: Text("""
                            Wear the watch overnight and grant Health access. \
                            Apple records beat-to-beat data only occasionally, so the first \
                            useful night can take a day or two to appear.
                            """)
                    )
                }
            }
            .navigationTitle("Tonight")
            .refreshable { await repository.refresh() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headline(_ night: AnalysedNight) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(night.summary.rmssd.isFinite ? String(format: "%.0f ms", night.summary.rmssd) : "—")
                    .font(.system(size: 52, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("Overnight RMSSD · median of \(night.summary.usedWindowCount) windows")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            LabeledContent("ln RMSSD", value: format(night.summary.lnRMSSD, "%.2f"))
            LabeledContent("SDNN", value: format(night.summary.sdnn, "%.0f ms"))
            LabeledContent("Mean HR", value: format(night.summary.meanHR, "%.0f bpm"))
            LabeledContent("Lowest window HR", value: format(night.summary.minHR, "%.0f bpm"))
            LabeledContent("pNN50", value: format(night.summary.pnn50, "%.1f%%"))
        } header: {
            Text(night.summary.nightOf.formatted(date: .complete, time: .omitted))
        }
    }

    @ViewBuilder
    private func quality(_ night: AnalysedNight) -> some View {
        Section("Data quality") {
            LabeledContent("Analysed time") {
                Text(Duration.seconds(night.summary.coverage)
                    .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
            }
            LabeledContent("Windows kept", value: "\(night.summary.usedWindowCount) of \(night.summary.windows.count)")
            LabeledContent("Beats corrected", value: format(night.summary.artifactFraction * 100, "%.1f%%"))
            if let sleep = night.summary.sleep {
                LabeledContent("Time asleep") {
                    Text(Duration.seconds(sleep.totalSleepTime)
                        .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                }
            }
            switch night.summary.quality {
            case .good:
                Label("Enough coverage to trend", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .sparse:
                Label("Thin coverage — treat this night as noisy", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .insufficient:
                Label("Not enough data to report", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func baseline(_ baseline: BaselineResult, night: AnalysedNight) -> some View {
        Section {
            switch baseline.status {
            case .establishingBaseline:
                Label("Building your baseline — \(baseline.nightsAvailable) of \(Baseline.minimumNights) nights",
                      systemImage: "hourglass")
            case .normal:
                Label("Within your normal range", systemImage: "equal.circle").foregroundStyle(.green)
            case .belowNormal:
                Label("Below your normal range", systemImage: "arrow.down.circle").foregroundStyle(.orange)
            case .aboveNormal:
                Label("Above your normal range", systemImage: "arrow.up.circle").foregroundStyle(.blue)
            }
            LabeledContent("60-night mean (ln)", value: format(baseline.longTermMean, "%.2f"))
            LabeledContent("Smallest worthwhile change", value: format(baseline.smallestWorthwhileChange, "±%.2f"))
            LabeledContent("7-night CV", value: format(baseline.shortTermCV, "%.1f%%"))
            LabeledContent("Tonight (z)", value: format(baseline.z, "%+.2f"))
        } header: {
            Text("Relative to you")
        } footer: {
            Text("""
                Bands are set by the smallest worthwhile change — half the between-night SD \
                of your own ln RMSSD — not by population norms. This is change detection on \
                a single-subject series, not a diagnosis.
                """)
        }
    }

    @ViewBuilder
    private func windows(_ night: AnalysedNight) -> some View {
        if !night.summary.windows.isEmpty {
            Section("Windows") {
                NavigationLink {
                    NightDetailView(night: night)
                } label: {
                    WindowStrip(windows: night.summary.windows)
                        .frame(height: 60)
                }
            }
        }
    }

    @ViewBuilder
    private func comparison(_ night: AnalysedNight) -> some View {
        let pairs = night.context.pairedWithOwnWindows(night.summary.windows)
        if !pairs.isEmpty {
            Section {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    LabeledContent(String(format: "Apple %.0f ms", pair.apple),
                                   value: String(format: "this app %.0f ms", pair.own))
                        .monospacedDigit()
                }
            } header: {
                Text("SDNN, same beats")
            } footer: {
                Text("""
                    Both columns are SDNN over the same heartbeat series. Any difference is \
                    processing — artifact correction and interval gating — not physiology.
                    """)
            }
        }
    }

    private func format(_ value: Double, _ spec: String) -> String {
        value.isFinite ? String(format: spec, value) : "—"
    }
}

/// A compact per-window overview: bar height is RMSSD, colour is sleep stage,
/// hatched bars were excluded for artifact load.
struct WindowStrip: View {
    let windows: [HRVWindow]

    var body: some View {
        GeometryReader { geometry in
            let values = windows.map(\.timeDomain.rmssd).filter(\.isFinite)
            let maximum = max(values.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(windows) { window in
                    let height = window.timeDomain.rmssd.isFinite
                        ? geometry.size.height * window.timeDomain.rmssd / maximum : 2
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(for: window).opacity(window.isLowQuality ? 0.3 : 1))
                        .frame(height: max(height, 2))
                }
            }
        }
    }

    private func color(for window: HRVWindow) -> Color {
        switch window.sleepStage {
        case .deep: return .indigo
        case .rem: return .teal
        case .core: return .blue
        case .awake: return .orange
        default: return .gray
        }
    }
}
