import SwiftUI
import HRVKit

/// Enrolment: a participant types the code and one-time secret the study gave them, and
/// the device gets a write-only token.
///
/// Nothing identifying is collected here, and that is deliberate rather than minimal. The
/// server holds health data keyed by an opaque code; the mapping from code to person stays
/// in the study's own enrolment log. Keeping the linking key out of the system that holds
/// the data is the single cheapest thing you can do for participant privacy, and it is
/// much easier to do on day one than to retrofit.
struct EnrolmentView: View {
    let sync: HealthSyncService

    @State private var participantCode = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Participant code", text: $participantCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Enrolment secret", text: $secret)
                } header: {
                    Text("From the study team")
                } footer: {
                    Text("""
                        Both were given to you by the research team. The secret works once, \
                        on this device.
                        """)
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange) }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy { ProgressView() } else { Text("Enrol this device") }
                    }
                    .disabled(busy || participantCode.isEmpty || secret.count < 8)
                } footer: {
                    Text("""
                        Once enrolled, this app uploads the beat-to-beat intervals, sleep \
                        stages and heart rate summaries your watch records to the study's \
                        server. It never uploads your name, email or anything else that \
                        identifies you, and it cannot read anyone else's data. You can stop \
                        at any time and ask the study team to delete what has been collected.
                        """)
                }
            }
            .navigationTitle("Join a study")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        error = nil
        do {
            try await sync.enrol(
                participantCode: participantCode.trimmingCharacters(in: .whitespaces),
                secret: secret.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

/// Sync status and controls, shown on the Data tab once a server is configured.
struct SyncSection: View {
    let sync: HealthSyncService
    let repository: NightRepository
    @State private var showEnrolment = false

    var body: some View {
        Section {
            if !sync.isEnrolled {
                Button("Join a study") { showEnrolment = true }
            } else {
                switch sync.state {
                case .idle, .notEnrolled:
                    Button("Upload new data now") { Task { await sync.sync(nights: repository.nights) } }
                case let .syncing(message):
                    Label(message, systemImage: "arrow.up.circle")
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await sync.sync(nights: repository.nights) } }
                case let .done(uploaded, duplicates, at):
                    LabeledContent("Last upload", value: at.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("New rows sent", value: "\(uploaded)")
                    // A high duplicate count is normal after a dropped connection and is
                    // shown rather than hidden, because "nothing uploaded" and "everything
                    // was already there" look identical otherwise.
                    LabeledContent("Already on server", value: "\(duplicates)")
                    Button("Upload new data now") { Task { await sync.sync(nights: repository.nights) } }
                }
            }
        } header: {
            Text("Study upload")
        } footer: {
            Text("""
                Uploads are one-way. This app can send your data to the study server and \
                cannot read anything back from it, including your own past uploads.
                """)
        }
        .sheet(isPresented: $showEnrolment) { EnrolmentView(sync: sync) }
    }
}
