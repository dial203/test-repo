import Foundation

public struct NonlinearMetrics: Sendable, Hashable, Codable {
    /// Detrended fluctuation analysis short-term scaling exponent (n = 4–16 beats).
    public let dfaAlpha1: Double
    /// DFA long-term exponent (n = 16–64 beats). Needs a long record to mean anything.
    public let dfaAlpha2: Double
    /// Sample entropy, m = 2, r = 0.2 × SDNN.
    public let sampleEntropy: Double
    /// Beats used.
    public let nnCount: Int
}

public enum Nonlinear {

    /// Minimum beats before DFA α1 is worth reporting. Below this the log–log fit is
    /// fitted to a handful of points and the exponent is unstable; the function returns
    /// `.nan` rather than a plausible-looking number.
    public static let minimumBeatsForDFA = 200
    /// Sample entropy is O(N²). Longer records are decimated to this length by taking a
    /// contiguous central window, which is reported alongside the value.
    public static let sampleEntropyMaxBeats = 5_000

    public static func metrics(for segments: [IntervalSegment]) -> NonlinearMetrics {
        // Nonlinear indices assume a continuous series, so use the longest gap-free run
        // rather than pooling across gaps.
        guard let longest = segments.max(by: { $0.count < $1.count }) else {
            return NonlinearMetrics(dfaAlpha1: .nan, dfaAlpha2: .nan, sampleEntropy: .nan, nnCount: 0)
        }
        let nn = longest.intervals
        return NonlinearMetrics(
            dfaAlpha1: dfa(nn, scales: Array(4 ... 16)),
            dfaAlpha2: dfa(nn, scales: Array(stride(from: 16, through: 64, by: 4))),
            sampleEntropy: sampleEntropy(nn),
            nnCount: nn.count
        )
    }

    /// Detrended fluctuation analysis scaling exponent over the given box sizes.
    public static func dfa(_ nn: [Double], scales: [Int]) -> Double {
        guard nn.count >= minimumBeatsForDFA, let maxScale = scales.max(),
              nn.count >= 4 * maxScale else { return .nan }

        let mean = Stats.mean(nn)
        var integrated = [Double](repeating: 0, count: nn.count)
        var running = 0.0
        for i in nn.indices { running += nn[i] - mean; integrated[i] = running }

        var logN: [Double] = [], logF: [Double] = []
        for n in scales {
            guard n >= 4, integrated.count >= 2 * n else { continue }
            let boxes = integrated.count / n
            var ss = 0.0
            let xs = (0 ..< n).map(Double.init)
            for b in 0 ..< boxes {
                let chunk = Array(integrated[b * n ..< (b + 1) * n])
                let fit = Stats.linearFit(x: xs, y: chunk)
                for i in 0 ..< n {
                    let resid = chunk[i] - (fit.slope * xs[i] + fit.intercept)
                    ss += resid * resid
                }
            }
            let f = (ss / Double(boxes * n)).squareRoot()
            guard f > 0 else { continue }
            logN.append(log(Double(n))); logF.append(log(f))
        }
        guard logN.count >= 3 else { return .nan }
        return Stats.linearFit(x: logN, y: logF).slope
    }

    /// Sample entropy with the conventional HRV parameters (m = 2, r = 0.2 × SDNN).
    public static func sampleEntropy(_ nn: [Double], m: Int = 2, rFactor: Double = 0.2) -> Double {
        var x = nn
        if x.count > sampleEntropyMaxBeats {
            let startIdx = (x.count - sampleEntropyMaxBeats) / 2
            x = Array(x[startIdx ..< startIdx + sampleEntropyMaxBeats])
        }
        let n = x.count
        guard n > m + 1 else { return .nan }
        let r = rFactor * Stats.sd(x)
        guard r > 0 else { return .nan }

        func matches(_ length: Int) -> Int {
            var count = 0
            let limit = n - length
            guard limit > 0 else { return 0 }
            for i in 0 ..< limit {
                var j = i + 1
                while j < limit {
                    var ok = true
                    for k in 0 ..< length where abs(x[i + k] - x[j + k]) > r { ok = false; break }
                    if ok { count += 1 }
                    j += 1
                }
            }
            return count
        }

        let b = matches(m)
        let a = matches(m + 1)
        guard b > 0, a > 0 else { return .nan }
        return -log(Double(a) / Double(b))
    }
}
