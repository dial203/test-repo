import Foundation
import SwiftData
import HRVKit

/// One analysed night on disk.
///
/// The full analysis (including every raw beat) is kept as an encoded blob so the night
/// can be re-analysed later under different preprocessing settings without waiting for
/// another night's data. The scalar columns exist only so trends and baselines can be
/// queried without decoding every blob.
@Model
final class StoredNight {
    @Attribute(.unique) var nightOf: Date

    var rmssd: Double
    var lnRMSSD: Double
    var sdnn: Double
    var meanHR: Double
    var minHR: Double
    var coverage: TimeInterval
    var artifactFraction: Double
    var windowCount: Int
    var qualityRaw: String
    var analysedAt: Date

    @Attribute(.externalStorage) var payload: Data

    var quality: NightDataQuality { NightDataQuality(rawValue: qualityRaw) ?? .insufficient }

    init(_ night: AnalysedNight) throws {
        self.nightOf = night.summary.nightOf
        self.rmssd = night.summary.rmssd
        self.lnRMSSD = night.summary.lnRMSSD
        self.sdnn = night.summary.sdnn
        self.meanHR = night.summary.meanHR
        self.minHR = night.summary.minHR
        self.coverage = night.summary.coverage
        self.artifactFraction = night.summary.artifactFraction
        self.windowCount = night.summary.usedWindowCount
        self.qualityRaw = night.summary.quality.rawValue
        self.analysedAt = night.analysedAt
        self.payload = try Export.json(night)
    }

    func decoded() throws -> AnalysedNight {
        try Export.decode(AnalysedNight.self, from: payload)
    }

    func update(from night: AnalysedNight) throws {
        rmssd = night.summary.rmssd
        lnRMSSD = night.summary.lnRMSSD
        sdnn = night.summary.sdnn
        meanHR = night.summary.meanHR
        minHR = night.summary.minHR
        coverage = night.summary.coverage
        artifactFraction = night.summary.artifactFraction
        windowCount = night.summary.usedWindowCount
        qualityRaw = night.summary.quality.rawValue
        analysedAt = night.analysedAt
        payload = try Export.json(night)
    }
}

/// User-facing analysis settings, persisted outside SwiftData so they are available before
/// the container exists.
struct AnalysisSettings: Codable, Equatable {
    var minNN: Double = 300
    var maxNN: Double = 2000
    var applyAdaptiveCorrection = true
    var qualityArtifactCeiling: Double = 0.05
    var excludeLowQualityWindows = true
    var restrictToMainSleepWindow = true
    var computeFrequencyDomain = false
    var computeNonlinear = false

    var analysisConfiguration: NightAnalysisConfiguration {
        var pre = PreprocessingConfiguration.standard
        pre.minNN = minNN
        pre.maxNN = maxNN
        pre.applyAdaptiveCorrection = applyAdaptiveCorrection
        pre.qualityArtifactCeiling = qualityArtifactCeiling

        var config = NightAnalysisConfiguration.standard
        config.preprocessing = pre
        config.excludeLowQualityWindows = excludeLowQualityWindows
        config.restrictToMainSleepWindow = restrictToMainSleepWindow
        config.computeFrequencyDomain = computeFrequencyDomain
        config.computeNonlinear = computeNonlinear
        return config
    }

    static let storageKey = "analysis.settings.v1"

    static func load() -> AnalysisSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(AnalysisSettings.self, from: data)
        else { return AnalysisSettings() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
