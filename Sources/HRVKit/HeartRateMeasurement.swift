import Foundation

/// Decoder for the Bluetooth SIG Heart Rate Measurement characteristic (0x2A37).
///
/// This is how a chest strap (Polar H10, Garmin HRM, Movesense, Wahoo) delivers real
/// beat-to-beat intervals. Apple Watch does not expose beat-to-beat data live to
/// third-party apps at all, so an external sensor is the only route to a dense,
/// continuous overnight RR series — and it is also the sensor you would want as the
/// criterion measure in a validation study.
///
/// The parser lives in the analysis core, with no CoreBluetooth import, so it can be
/// tested against byte fixtures on any platform.
/// Specification: Bluetooth SIG GATT Heart Rate Service, characteristic 0x2A37.
public struct HeartRateMeasurement: Sendable, Hashable {

    public enum SensorContact: Sendable, Hashable {
        case notSupported
        case notDetected
        case detected
    }

    /// Instantaneous heart rate, bpm.
    public let heartRate: Int
    /// RR intervals in milliseconds, oldest first. Empty when the sensor does not report
    /// them — many optical wrist straps do not, and a strap in "HR only" mode will not
    /// either, which is worth surfacing to the user rather than silently recording nothing.
    public let rrIntervals: [Double]
    public let sensorContact: SensorContact
    /// Energy expended in kilojoules, when present.
    public let energyExpended: Int?

    /// RR intervals arrive in units of 1/1024 s.
    static let rrResolution = 1024.0

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }

        let flags = bytes[0]
        let is16Bit = flags & 0x01 != 0
        let contactSupported = flags & 0x04 != 0
        let contactDetected = flags & 0x02 != 0
        let hasEnergy = flags & 0x08 != 0
        let hasRR = flags & 0x10 != 0

        var index = 1
        let hr: Int
        if is16Bit {
            guard bytes.count >= index + 2 else { return nil }
            hr = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        } else {
            hr = Int(bytes[index])
            index += 1
        }

        var energy: Int?
        if hasEnergy {
            guard bytes.count >= index + 2 else { return nil }
            energy = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        }

        var rr: [Double] = []
        if hasRR {
            while index + 1 < bytes.count {
                let raw = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
                rr.append(Double(raw) * 1000.0 / Self.rrResolution)
                index += 2
            }
        }

        self.heartRate = hr
        self.rrIntervals = rr
        self.energyExpended = energy
        self.sensorContact = contactSupported ? (contactDetected ? .detected : .notDetected)
                                              : .notSupported
    }
}

/// Accumulates streamed RR intervals into a beat train suitable for
/// `HKHeartbeatSeriesBuilder`, inserting gap markers where the stream dropped out.
///
/// A BLE notification carries the RR intervals measured since the previous notification,
/// so the receive timestamp is not the beat timestamp. Beats are therefore placed by
/// accumulating the interval durations themselves, and drift against wall clock is used
/// only to detect dropouts.
public struct BeatAccumulator: Sendable {

    /// Wall-clock drift beyond which the stream is treated as having dropped out and the
    /// next beat is flagged `precededByGap`.
    public var dropoutTolerance: TimeInterval = 2.0
    public private(set) var start: Date?
    public private(set) var beats: [Beat] = []
    private var elapsed: TimeInterval = 0
    private var lastReceived: Date?

    public init(dropoutTolerance: TimeInterval = 2.0) {
        self.dropoutTolerance = dropoutTolerance
    }

    public var beatCount: Int { beats.count }

    /// Feed one notification's worth of RR intervals.
    /// - Parameter receivedAt: when the notification arrived, used only for dropout detection.
    public mutating func append(rrIntervals: [Double], receivedAt: Date) {
        guard !rrIntervals.isEmpty else { lastReceived = receivedAt; return }

        if start == nil {
            // Anchor the series at the first beat of the first packet.
            let packetDuration = rrIntervals.reduce(0, +) / 1000.0
            start = receivedAt.addingTimeInterval(-packetDuration)
            beats.append(Beat(offset: 0, precededByGap: false))
        }

        var gap = false
        if let last = lastReceived {
            let wallGap = receivedAt.timeIntervalSince(last)
            let reported = rrIntervals.reduce(0, +) / 1000.0
            if wallGap - reported > dropoutTolerance { gap = true }
        }

        for (i, ms) in rrIntervals.enumerated() {
            elapsed += ms / 1000.0
            beats.append(Beat(offset: elapsed, precededByGap: gap && i == 0))
        }
        lastReceived = receivedAt
    }

    public func makeSeries(sourceIdentifier: String?, deviceName: String?) -> IBISeries? {
        guard let start, beats.count >= 2 else { return nil }
        return IBISeries(start: start, beats: beats,
                         sourceIdentifier: sourceIdentifier, deviceName: deviceName)
    }

    public mutating func reset() {
        start = nil; beats = []; elapsed = 0; lastReceived = nil
    }
}
