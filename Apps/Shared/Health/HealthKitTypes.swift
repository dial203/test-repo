import Foundation
import HealthKit

/// The HealthKit object types this app touches, in one place so the authorization sheet,
/// the background observers and the readers can never drift apart.
enum HealthTypes {

    /// Beat-to-beat data. This is the only Apple Watch source of true inter-beat
    /// intervals available to a third-party app: `HKHeartbeatSeriesSample` carries the
    /// beat timestamps that back each of Apple's background HRV measurements.
    static let heartbeatSeries: HKSeriesType = .heartbeat()

    /// Apple's own SDNN value for the same window. Read so the app can put its RMSSD
    /// next to Apple's SDNN rather than silently replacing it.
    static let hrvSDNN = HKQuantityType(.heartRateVariabilitySDNN)

    static let heartRate = HKQuantityType(.heartRate)
    static let restingHeartRate = HKQuantityType(.restingHeartRate)
    static let respiratoryRate = HKQuantityType(.respiratoryRate)
    static let sleepAnalysis = HKCategoryType(.sleepAnalysis)

    static var read: Set<HKObjectType> {
        [heartbeatSeries, hrvSDNN, heartRate, restingHeartRate, respiratoryRate, sleepAnalysis]
    }

    /// Written only when the external-sensor recorder is used: RR intervals streamed from
    /// a BLE chest strap are saved back as heartbeat series so they live alongside the
    /// watch's own data.
    static var share: Set<HKSampleType> {
        [heartbeatSeries]
    }

    // Units.
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let ms = HKUnit.secondUnit(with: .milli)
    static let breathsPerMinute = HKUnit.count().unitDivided(by: .minute())
}

extension HKCategoryValueSleepAnalysis {
    var stage: SleepStage {
        switch self {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepCore: return .core
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        case .asleepUnspecified: return .unspecified
        @unknown default: return .unspecified
        }
    }
}
