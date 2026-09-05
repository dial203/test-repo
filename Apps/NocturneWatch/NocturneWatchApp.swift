import SwiftUI
import HealthKit
import HRVKit

@main
struct NocturneWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchRootView() }
    }
}

struct WatchRootView: View {
    @StateObject private var session = OvernightSession()
    @StateObject private var recorder = ExternalSensorRecorder()
    @State private var showSessionWarning = false

    var body: some View {
        NavigationStack {
            List {
                Section("Chest strap") {
                    switch recorder.state {
                    case .idle, .finished, .failed:
                        Button("Record from strap") { recorder.start() }
                    case .scanning:
                        Text("Searching…")
                    case let .connecting(name):
                        Text("Connecting to \(name)")
                    case let .recording(name, beats):
                        VStack(alignment: .leading) {
                            Text(name).font(.caption)
                            Text("\(beats) beats").font(.headline).monospacedDigit()
                        }
                        Button("Stop and save", role: .destructive) { Task { await recorder.stop() } }
                    case let .bluetoothUnavailable(message):
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    if let hr = recorder.lastHeartRate {
                        LabeledContent("Heart rate", value: "\(hr) bpm")
                    }
                }

                Section {
                    switch session.state {
                    case .idle, .ended, .failed:
                        Button("Start overnight session") { showSessionWarning = true }
                    case let .running(since):
                        LabeledContent("Running since", value: since.formatted(date: .omitted, time: .shortened))
                        if let hr = session.currentHeartRate {
                            LabeledContent("Heart rate", value: String(format: "%.0f bpm", hr))
                        }
                        Button("End session", role: .destructive) { session.stop() }
                    }
                    if case let .failed(message) = session.state {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Watch sensors")
                } footer: {
                    Text("Keeps sensors active overnight. Does not provide beat-to-beat data.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Nocturne")
            .alert("This costs battery", isPresented: $showSessionWarning) {
                Button("Start anyway") { session.start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                    An overnight session drains the watch battery substantially and logs a \
                    workout every night. It does not give the app beat-to-beat data — Apple \
                    does not expose that to third-party apps. It may increase how often the \
                    watch records its own heartbeat series, but that is undocumented; check \
                    windows-per-night on the phone to see whether it helps you.
                    """)
            }
            .task { try? await HealthKitService.shared.requestAuthorization() }
        }
    }
}
