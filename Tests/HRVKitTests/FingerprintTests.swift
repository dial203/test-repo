import XCTest
@testable import HRVKit

final class SHA256Tests: XCTestCase {

    /// FIPS 180-4 / NIST published vectors. If these pass, the implementation is right.
    func testKnownVectors() {
        XCTAssertEqual(
            SHA256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // 448-bit boundary case: the message length forces a second padding block.
        XCTAssertEqual(
            SHA256.hex(String(repeating: "a", count: 55)),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
        )
        XCTAssertEqual(
            SHA256.hex(String(repeating: "a", count: 56)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        )
        XCTAssertEqual(
            SHA256.hex(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }
}

final class ConfigurationFingerprintTests: XCTestCase {

    func testSameConfigurationGivesTheSameHash() {
        let a = NightAnalysisConfiguration.standard
        let b = NightAnalysisConfiguration.standard
        XCTAssertEqual(ConfigurationFingerprint.hash(a), ConfigurationFingerprint.hash(b))
        XCTAssertEqual(ConfigurationFingerprint.hash(a).count, 16)
    }

    /// The whole point: a preprocessing change must produce a different key, so two
    /// analyses of the same night cannot be silently conflated.
    func testEverySettingThatChangesResultsChangesTheHash() {
        let base = NightAnalysisConfiguration.standard
        let baseHash = ConfigurationFingerprint.hash(base)

        var ceiling = base
        ceiling.preprocessing.qualityArtifactCeiling = 0.15
        XCTAssertNotEqual(ConfigurationFingerprint.hash(ceiling), baseHash)

        var correction = base
        correction.preprocessing.applyAdaptiveCorrection = false
        XCTAssertNotEqual(ConfigurationFingerprint.hash(correction), baseHash)

        var range = base
        range.preprocessing.maxNN = 1800
        XCTAssertNotEqual(ConfigurationFingerprint.hash(range), baseHash)

        var windowing = base
        windowing.windowing = .fixed(seconds: 300, minimumFill: 0.8)
        XCTAssertNotEqual(ConfigurationFingerprint.hash(windowing), baseHash)

        var spectral = base
        spectral.computeFrequencyDomain = true
        XCTAssertNotEqual(ConfigurationFingerprint.hash(spectral), baseHash)

        var alpha = base
        alpha.preprocessing.corrector.alpha = 4.0
        XCTAssertNotEqual(ConfigurationFingerprint.hash(alpha), baseHash)

        var sleepWindow = base
        sleepWindow.restrictToMainSleepWindow = false
        XCTAssertNotEqual(ConfigurationFingerprint.hash(sleepWindow), baseHash)
    }

    /// Change detector for the configuration schema.
    ///
    /// A hash that shifts between app builds fragments a study's data into groups that no
    /// longer pool, so any movement in this value should be deliberate. Note the scope of
    /// the claim: the literal is whatever the toolchain running this suite produces, and
    /// `JSONEncoder`'s floating-point formatting is not guaranteed identical between
    /// swift-corelibs-foundation and Apple's Foundation. So this pins the *schema*, not
    /// the byte-for-byte value an iPhone computes. Nothing compares the two — the server
    /// treats `config_hash` as an opaque string supplied by the device — so a divergence
    /// between CI and device would be harmless. What would not be harmless is a field
    /// added or renamed without anyone noticing, and that is what this catches.
    func testStandardConfigurationHashIsPinned() {
        XCTAssertEqual(
            ConfigurationFingerprint.hash(.standard),
            "ad03842e11fa51a1",
            """
            The fingerprint of the standard configuration changed. If that was intentional \
            (a field added or renamed), update this literal and record it — every night \
            already collected is keyed by the old hash and will no longer pool with new data.
            """
        )
    }

    func testCanonicalJSONIsSortedAndCompact() {
        let json = ConfigurationFingerprint.canonicalJSON(.standard)
        XCTAssertFalse(json.contains("\n"), "whitespace would make the hash formatting-dependent")
        XCTAssertTrue(json.contains("preprocessing"))

        // Keys at the top level must be in sorted order.
        let topLevelKeys = ["bands", "computeFrequencyDomain", "computeNonlinear",
                            "excludeLowQualityWindows", "minimumCoverageSeconds",
                            "minimumWindowsForSummary", "preprocessing",
                            "restrictToMainSleepWindow", "spectralMethod", "windowing"]
        let positions = topLevelKeys.compactMap { json.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertEqual(positions.count, topLevelKeys.count, "a configuration key is missing")
        XCTAssertEqual(positions, positions.sorted())
    }
}
