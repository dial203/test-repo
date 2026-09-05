import Foundation

/// Small, dependency-free numeric helpers. Sample (n-1) denominators throughout unless
/// a function name says otherwise — HRV convention follows the Task Force (1996) report.
public enum Stats {

    public static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }

    /// Sample standard deviation (n-1). `.nan` for n < 2.
    public static func sd(_ x: [Double]) -> Double {
        guard x.count > 1 else { return .nan }
        let m = mean(x)
        let ss = x.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(x.count - 1)).squareRoot()
    }

    /// Population standard deviation (n).
    public static func sdPopulation(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)).squareRoot()
    }

    public static func variance(_ x: [Double]) -> Double {
        let s = sd(x); return s * s
    }

    public static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Linear-interpolation percentile (type 7, matching R's default and NumPy).
    public static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        if x.count == 1 { return x[0] }
        let s = x.sorted()
        let h = (Double(s.count) - 1) * min(max(p, 0), 1)
        let lo = Int(h.rounded(.down)), hi = Int(h.rounded(.up))
        return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
    }

    /// Quartile deviation, (Q3 − Q1) / 2. Used by the adaptive artifact thresholds.
    public static func quartileDeviation(_ x: [Double]) -> Double {
        (percentile(x, 0.75) - percentile(x, 0.25)) / 2.0
    }

    /// Trimmed mean, dropping `fraction` from each tail.
    public static func trimmedMean(_ x: [Double], fraction: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        let f = min(max(fraction, 0), 0.49)
        let s = x.sorted()
        let k = Int((Double(s.count) * f).rounded(.down))
        let kept = s.dropFirst(k).dropLast(k)
        return kept.isEmpty ? median(x) : mean(Array(kept))
    }

    /// Centred running median with an odd window, edges handled by shrinking the window.
    public static func runningMedian(_ x: [Double], window: Int) -> [Double] {
        guard !x.isEmpty else { return [] }
        return slidingQuantiles(x, window: window, probs: [0.5]).map { $0[0] }
    }

    /// Ordinary least squares slope and intercept of y on x.
    public static func linearFit(x: [Double], y: [Double]) -> (slope: Double, intercept: Double) {
        precondition(x.count == y.count)
        guard x.count > 1 else { return (.nan, .nan) }
        let mx = mean(x), my = mean(y)
        var num = 0.0, den = 0.0
        for i in x.indices {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        guard den != 0 else { return (.nan, .nan) }
        let slope = num / den
        return (slope, my - slope * mx)
    }
}

extension Stats {

    /// Centred sliding-window quantiles in O(n · w) rather than O(n · w log w).
    ///
    /// The window shrinks at both edges (equivalent to pandas' `min_periods=1`), which is
    /// what the adaptive artifact thresholds expect. Quantiles use the same type-7
    /// interpolation as `percentile(_:_:)`, so results are identical to the naive form.
    public static func slidingQuantiles(
        _ x: [Double], window: Int, probs: [Double]
    ) -> [[Double]] {
        let n = x.count
        guard n > 0, !probs.isEmpty else { return [] }
        let w = max(1, window % 2 == 0 ? window + 1 : window)
        let half = w / 2

        var sorted: [Double] = []
        sorted.reserveCapacity(min(n, w))

        func insert(_ v: Double) {
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < v { lo = mid + 1 } else { hi = mid } }
            sorted.insert(v, at: lo)
        }
        func remove(_ v: Double) {
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < v { lo = mid + 1 } else { hi = mid } }
            if lo < sorted.count { sorted.remove(at: lo) }
        }
        func quantile(_ p: Double) -> Double {
            let m = sorted.count
            if m == 0 { return .nan }
            if m == 1 { return sorted[0] }
            let h = (Double(m) - 1) * min(max(p, 0), 1)
            let l = Int(h.rounded(.down)), u = Int(h.rounded(.up))
            return sorted[l] + (h - Double(l)) * (sorted[u] - sorted[l])
        }

        var prevLo = 0, prevHi = -1
        var out = [[Double]](repeating: [], count: n)
        for i in 0 ..< n {
            let lo = max(0, i - half), hi = min(n - 1, i + half)
            if prevHi < prevLo {
                for k in lo ... hi { insert(x[k]) }
            } else {
                if hi > prevHi { for k in (prevHi + 1) ... hi { insert(x[k]) } }
                if lo > prevLo { for k in prevLo ... (lo - 1) { remove(x[k]) } }
            }
            prevLo = lo; prevHi = hi
            out[i] = probs.map(quantile)
        }
        return out
    }
}
