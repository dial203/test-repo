import Foundation
import HRVKit
import os

enum SyncError: LocalizedError {
    case notEnrolled
    case enrolmentRejected(String)
    case http(Int, String)
    case transport(String)
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .notEnrolled:
            return "This device has not been enrolled in a study yet."
        case let .enrolmentRejected(message):
            return message
        case let .http(code, body):
            return "Server returned \(code): \(body)"
        case let .transport(message):
            return "Could not reach the server: \(message)"
        case .payloadTooLarge:
            return "This batch is too large to upload. It will be split and retried."
        }
    }

    /// Whether retrying the same request unchanged could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case let .http(code, _): return code == 429 || (500 ... 599).contains(code)
        case .notEnrolled, .enrolmentRejected, .payloadTooLarge: return false
        }
    }
}

/// HTTP client for the sync service.
///
/// The device token is kept in the keychain, not `UserDefaults`: it is a bearer credential
/// for a participant's health data and `UserDefaults` is a plist in the app container.
actor SyncAPIClient {

    private let baseURL: URL
    private let session: URLSession
    private let log = Logger(subsystem: "app.nocturne", category: "sync.api")

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private var deviceInfo: SyncWire.DeviceInfoOut {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if os(watchOS)
        let system = "watchOS"
        #else
        let system = "iOS"
        #endif
        return SyncWire.DeviceInfoOut(
            model: nil, system_version: system, app_version: "\(version) (\(build))"
        )
    }

    // MARK: - Enrolment

    func enrol(participantCode: String, secret: String) async throws -> String {
        let body = SyncWire.EnrolRequest(
            participant_code: participantCode, enrolment_secret: secret, device: deviceInfo
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/enrol"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SyncWire.encoder.encode(body)

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("no response")
        }
        guard http.statusCode == 200 else {
            // Surface the server's own wording: it distinguishes "already enrolled" from
            // "locked after too many attempts", and the participant needs to know which.
            let detail = Self.detail(from: data) ?? "Enrolment failed"
            throw SyncError.enrolmentRejected(detail)
        }
        return try SyncWire.decoder.decode(SyncWire.EnrolResponse.self, from: data).device_token
    }

    // MARK: - Ingest

    func upload(_ envelope: SyncWire.Envelope, token: String) async throws -> SyncWire.IngestResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ingest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try SyncWire.encoder.encode(envelope)
        // Uploads happen overnight on a phone that may be on a slow connection.
        request.timeoutInterval = 120

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("no response")
        }
        switch http.statusCode {
        case 200:
            return try SyncWire.decoder.decode(SyncWire.IngestResult.self, from: data)
        case 413:
            throw SyncError.payloadTooLarge
        default:
            throw SyncError.http(http.statusCode, Self.detail(from: data) ?? "")
        }
    }

    func syncState(token: String, since: Date?) async throws -> SyncWire.SyncStateResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/sync/state"), resolvingAgainstBaseURL: false
        )!
        if let since {
            // URLComponents percent-encodes the "+" in the offset. Without that the server
            // sees a space where the offset sign should be.
            components.queryItems = [
                URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))
            ]
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SyncError.http(code, Self.detail(from: data) ?? "")
        }
        return try SyncWire.decoder.decode(SyncWire.SyncStateResponse.self, from: data)
    }

    // MARK: - Plumbing

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SyncError.transport(error.localizedDescription)
        }
    }

    /// FastAPI puts the human-readable reason in `detail`, which may be a string or the
    /// validation-error array.
    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] else { return nil }
        if let text = detail as? String { return text }
        if let items = detail as? [[String: Any]] {
            return items.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        }
        return nil
    }
}

/// Keychain storage for the device token.
enum TokenStore {
    private static let service = "app.nocturne.sync"
    private static let account = "device-token"

    static func save(_ token: String) throws {
        try? delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            // The token is only needed while the app runs, and a background sync only runs
            // after first unlock, so this is the tightest accessibility that still works.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SyncError.transport("keychain write failed (\(status))")
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncError.transport("keychain delete failed (\(status))")
        }
    }
}
