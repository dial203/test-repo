import Foundation
@testable import HRVKit

/// Deterministic RNG so every test result is reproducible on any machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// Box–Muller.
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

enum Synthetic {

    /// A clean tachogram with respiratory sinus arrhythmia plus white measurement noise.
    /// - Parameters:
    ///   - meanNN: mean interval, ms
    ///   - rsaAmplitude: peak amplitude of the respiratory modulation, ms
    ///   - respirationHz: respiratory frequency, Hz (0.25 Hz = 15 breaths/min)
    ///   - noiseSD: SD of added white noise, ms
    static func tachogram(
        beats: Int, meanNN: Double = 1000, rsaAmplitude: Double = 30,
        respirationHz: Double = 0.25, noiseSD: Double = 0, seed: UInt64 = 42
    ) -> [Double] {
        var rng = SplitMix64(seed: seed)
        var out: [Double] = []
        var t = 0.0
        for _ in 0 ..< beats {
            let nn = meanNN
                + rsaAmplitude * sin(2 * .pi * respirationHz * t)
                + (noiseSD > 0 ? noiseSD * rng.gaussian() : 0)
            out.append(nn)
            t += nn / 1000.0
        }
        return out
    }

    /// Convert intervals (ms) to beat times (s) starting at 0.
    static func peaks(from intervalsMS: [Double]) -> [Double] {
        var out = [0.0]
        var t = 0.0
        for ms in intervalsMS { t += ms / 1000.0; out.append(t) }
        return out
    }

    static func intervals(fromPeaks peaks: [Double]) -> [Double] {
        zip(peaks.dropFirst(), peaks).map { ($0 - $1) * 1000.0 }
    }

    static func whiteNoise(_ n: Int, sd: Double = 1, seed: UInt64 = 7) -> [Double] {
        var rng = SplitMix64(seed: seed)
        return (0 ..< n).map { _ in sd * rng.gaussian() }
    }

    static func randomWalk(_ n: Int, sd: Double = 1, seed: UInt64 = 11) -> [Double] {
        var acc = 0.0
        return whiteNoise(n, sd: sd, seed: seed).map { acc += $0; return acc }
    }
}

extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
