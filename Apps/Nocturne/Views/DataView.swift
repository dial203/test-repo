import SwiftUI
import UniformTypeIdentifiers
import HRVKit

struct DataView: View {
    @Bindable var repository: NightRepository
    @StateObject private var recorder = ExternalSensorRecorder()
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Refresh from Health") { Task { await repository.refresh() } }
                    Button("Backfill last 90 nights") { Task { await repository.refresh(backfillDays: 90) } }
                } header: {
                    Text("Health")
                } footer: {
                    Text("""
                        Backfill only finds nights where the watch happened to record a heartbeat \
                        series. Coverage before you started wearing it to bed will be thin.
                        """)
                }

                Section("Export") {
                    exportButton("Nights (one row per night)", ext: "csv") {
                        Export.nightsCSV(repository.nights.map(\.summary))
                    }
                    exportButton("Windows (one row per window)", ext: "csv") {
                        Export.windowsCSV(repository.nights.map(\.summary))
                    }
                    exportButton("Corrected NN intervals", ext: "csv") {
                        Export.intervalsCSV(repository.nights.flatMap {
                            Preprocessor.clean($0.rawSeries,
                                               configuration: repository.settings.analysisConfiguration.preprocessing)
                        })
                    }
                    exportButton("Raw beat timestamps", ext: "csv") {
                        Export.beatsCSV(repository.nights.flatMap(\.rawSeries))
                    }
                    exportButton("Everything (JSON)", ext: "json") {
                        (try? String(data: Export.json(repository.nights), encoding: .utf8)) ?? ""
                    }
                }

                settingsSection
                recorderSection
            }
            .navigationTitle("Data")
            .sheet(item: Binding(
                get: { exportURL.map { ExportFile(url: $0) } },
                set: { if $0 == nil { exportURL = nil } }
            )) { file in
                ShareLink(item: file.url) { Label("Share export", systemImage: "square.and.arrow.up") }
                    .presentationDetents([.medium])
            }
            .alert("Export failed", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsSection: some View {
        Section {
            Toggle("Adaptive artifact correction", isOn: Binding(
                get: { repository.settings.applyAdaptiveCorrection },
                set: { repository.settings.applyAdaptiveCorrection = $0 }
            ))
            Toggle("Exclude low-quality windows", isOn: Binding(
                get: { repository.settings.excludeLowQualityWindows },
                set: { repository.settings.excludeLowQualityWindows = $0 }
            ))
            Toggle("Restrict to the sleep period", isOn: Binding(
                get: { repository.settings.restrictToMainSleepWindow },
                set: { repository.settings.restrictToMainSleepWindow = $0 }
            ))
            Toggle("Frequency-domain indices", isOn: Binding(
                get: { repository.settings.computeFrequencyDomain },
                set: { repository.settings.computeFrequencyDomain = $0 }
            ))
            Stepper(
                "Artifact ceiling \(Int(repository.settings.qualityArtifactCeiling * 100))%",
                value: Binding(
                    get: { repository.settings.qualityArtifactCeiling },
                    set: { repository.settings.qualityArtifactCeiling = $0 }
                ),
                in: 0.01 ... 0.25, step: 0.01
            )
            Button("Re-analyse stored nights") { Task { await repository.reanalyseAll() } }
        } header: {
            Text("Analysis")
        } footer: {
            Text("""
                Changing these re-runs the analysis on beats already on this device — no \
                data is refetched and nothing is lost, so you can compare settings on the \
                same nights.
                """)
        }
    }

    // MARK: - External sensor

    @ViewBuilder
    private var recorderSection: some View {
        Section {
            switch recorder.state {
            case .idle, .finished, .failed:
                Button("Start recording from a chest strap") { recorder.start() }
            case .scanning:
                Label("Looking for a heart rate sensor…", systemImage: "dot.radiowaves.left.and.right")
            case let .connecting(name):
                Label("Connecting to \(name)…", systemImage: "link")
            case let .recording(name, beats):
                Label("\(name) · \(beats) beats", systemImage: "waveform.path.ecg")
                Button("Stop and save", role: .destructive) { Task { await recorder.stop() } }
            case let .bluetoothUnavailable(message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if case let .finished(beats, series) = recorder.state {
                Text("Saved \(beats) beats across \(series) series.").foregroundStyle(.secondary)
            }
            if recorder.packetsWithoutIntervals > 20 {
                Label("This sensor is reporting heart rate but no RR intervals — HRV cannot be computed from it.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("External sensor")
        } footer: {
            Text("""
                Apple Watch does not expose live beat-to-beat data to third-party apps, and \
                its own heartbeat series are recorded only occasionally. A Bluetooth chest \
                strap that reports RR intervals (Polar H10, Garmin HRM-Pro, Movesense) gives \
                a continuous overnight series and is the sensor to use as a criterion measure.
                """)
        }
    }

    // MARK: - Export plumbing

    @ViewBuilder
    private func exportButton(_ title: String, ext: String, build: @escaping () -> String) -> some View {
        Button(title) {
            do {
                let name = "nocturne-\(title.split(separator: " ").first!.lowercased())-\(Date().formatted(.iso8601.year().month().day())).\(ext)"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try build().write(to: url, atomically: true, encoding: .utf8)
                exportURL = url
            } catch {
                exportError = error.localizedDescription
            }
        }
        .disabled(repository.nights.isEmpty)
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
