import Foundation

/// A stable content hash of an analysis configuration.
///
/// Derived values are stored and exported keyed by this hash, so a number can always be
/// traced to the settings that produced it. That matters because the preprocessing choices
/// in this library move RMSSD by more than most readers assume: change the artifact
/// ceiling or the aggregation window and you get a different, equally defensible answer.
/// Keying on the configuration turns "which settings was this?" from a guess into a lookup.
///
/// The hash must be identical for the same settings on every device and across app
/// versions, so it is computed from canonical JSON — sorted keys, no whitespace — of the
/// configuration alone. It deliberately excludes the library version: a bug fix that
/// changes a computed value is a different concern, tracked by the separately recorded
/// `hrvkitVersion`.
public enum ConfigurationFingerprint {

    /// Hex SHA-256 of the canonical encoding, truncated to 16 characters.
    ///
    /// 64 bits is ample: this namespaces a handful of configurations per study, and a
    /// collision would need two settings dictionaries chosen adversarially. The short form
    /// is legible in a CSV column and in a URL query.
    public static func hash(_ configuration: NightAnalysisConfiguration) -> String {
        String(fullHash(configuration).prefix(16))
    }

    public static func fullHash(_ configuration: NightAnalysisConfiguration) -> String {
        fullHash(of: configuration)
    }

    /// Fingerprint any encodable configuration, so preprocessing settings can be recorded
    /// and compared on their own — not only as part of a whole night configuration.
    public static func hash<T: Encodable>(of value: T) -> String {
        String(fullHash(of: value).prefix(16))
    }

    public static func fullHash<T: Encodable>(of value: T) -> String {
        guard let data = try? canonicalEncoder.encode(value) else {
            return String(repeating: "0", count: 64)
        }
        return SHA256.hex(data)
    }

    /// The canonical JSON a fingerprint is computed over. Exposed for debugging a
    /// mismatch: if two devices disagree on a hash, diff this.
    public static func canonicalJSON(_ configuration: NightAnalysisConfiguration) -> String {
        guard let data = try? canonicalEncoder.encode(configuration),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted keys, and explicitly no pretty-printing: whitespace would make the hash
        // depend on the encoder's formatting rather than the settings.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return encoder
    }()
}
