import SwiftUI
import Charts
import HRVKit

struct TrendView: View {
    @Bindable var repository: NightRepository
    @State private var metric: Metric = .lnRMSSD
    @State private var span = 60

    enum Metric: String, CaseIterable, Identifiable {
        case lnRMSSD = "ln RMSSD"
        case rmssd = "RMSSD"
        case sdnn = "SDNN"
        case meanHR = "Mean HR"
        var id: String { rawValue }

        func value(_ night: AnalysedNight) -> Double {
            switch self {
            case .lnRMSSD: return night.summary.lnRMSSD
            case .rmssd: return night.summary.rmssd
            case .sdnn: return night.summary.sdnn
            case .meanHR: return night.summary.meanHR
            }
        }
    }

    private var points: [(night: AnalysedNight, value: Double)] {
        repository.nights
            .suffix(span)
            .map { ($0, metric.value($0)) }
            .filter { $0.value.isFinite }
    }

    private var rolling: [BaselinePoint] {
        Baseline.rollingMean(points.map {
            BaselinePoint(nightOf: $0.night.summary.nightOf, lnRMSSD: $0.value)
        }, window: 7)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Metric", selection: $metric) {
                        ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if points.count < 2 {
                        ContentUnavailableView("Not enough nights yet", systemImage: "chart.xyaxis.line")
                            .frame(height: 200)
                    } else {
                        chart.frame(height: 260)
                    }
                }

                if metric == .lnRMSSD, let baseline = repository.currentBaseline {
                    Section {
                        LabeledContent("7-night mean", value: String(format: "%.2f", baseline.shortTermMean))
                        LabeledContent("7-night CV", value: String(format: "%.1f%%", baseline.shortTermCV))
                        LabeledContent("60-night mean", value: String(format: "%.2f", baseline.longTermMean))
                        LabeledContent("60-night SD", value: String(format: "%.2f", baseline.longTermSD))
                    } header: {
                        Text("Baseline")
                    } footer: {
                        Text("""
                            The shaded band is the 60-night mean ± the smallest worthwhile change. \
                            A rising CV alongside a falling mean is the pattern reported in \
                            endurance athletes approaching non-functional overreaching; on its own \
                            it is a flag to look at training and sleep, not a finding.
                            """)
                    }
                }

                Section("Nights") {
                    ForEach(repository.nights.reversed()) { night in
                        NavigationLink {
                            NightDetailView(night: night)
                        } label: {
                            NightRow(night: night, metric: metric)
                        }
                    }
                }
            }
            .navigationTitle("Trend")
        }
    }

    @ViewBuilder
    private var chart: some View {
        let baseline = metric == .lnRMSSD ? repository.currentBaseline : nil
        Chart {
            if let baseline, baseline.status != .establishingBaseline {
                RectangleMark(
                    yStart: .value("Lower", baseline.longTermMean - baseline.smallestWorthwhileChange),
                    yEnd: .value("Upper", baseline.longTermMean + baseline.smallestWorthwhileChange)
                )
                .foregroundStyle(.green.opacity(0.10))
                RuleMark(y: .value("Baseline", baseline.longTermMean))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }

            ForEach(points, id: \.night.id) { point in
                PointMark(
                    x: .value("Night", point.night.summary.nightOf),
                    y: .value(metric.rawValue, point.value)
                )
                .symbolSize(point.night.summary.quality == .good ? 40 : 18)
                .foregroundStyle(point.night.summary.quality == .good ? Color.accentColor : .secondary)
            }

            ForEach(rolling, id: \.nightOf) { point in
                LineMark(
                    x: .value("Night", point.nightOf),
                    y: .value("7-night mean", point.lnRMSSD),
                    series: .value("Series", "rolling")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartYAxisLabel(metric == .meanHR ? "bpm" : (metric == .lnRMSSD ? "ln(ms)" : "ms"))
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: max(1, span / 8))) }
    }
}

struct NightRow: View {
    let night: AnalysedNight
    let metric: TrendView.Metric

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(night.summary.nightOf.formatted(date: .abbreviated, time: .omitted))
                Text("\(night.summary.usedWindowCount) windows · \(Int(night.summary.artifactFraction * 100))% corrected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(metric.value(night).isFinite ? String(format: "%.1f", metric.value(night)) : "—")
                .monospacedDigit()
            if night.summary.quality != .good {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).imageScale(.small)
            }
        }
    }
}
