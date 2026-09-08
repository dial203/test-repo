import Foundation

/// Where the study server lives.
///
/// Read from the app's Info.plist (`NocturneServerURL`) rather than hard-coded, so the
/// same source tree builds a personal install with no server and a study build pointed at
/// one. When the key is absent the app is entirely local: no sync UI, no network calls,
/// nothing leaves the device.
enum ServerConfiguration {
    static var current: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "NocturneServerURL") as? String,
              !raw.isEmpty,
              let url = URL(string: raw) else { return nil }
        // Refuse cleartext. Health data over http is not a warning-level problem, and a
        // misconfigured build should fail loudly at the first call rather than quietly
        // transmit in the open.
        guard url.scheme == "https" else {
            assertionFailure("NocturneServerURL must be https, got \(raw)")
            return nil
        }
        return url
    }
}
