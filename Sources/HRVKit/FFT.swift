import Foundation

/// Minimal iterative radix-2 Cooley–Tukey FFT.
///
/// Deliberately hand-rolled rather than using Accelerate so the analysis core stays
/// portable and its results are bit-identical on device and in Linux CI.
enum FFT {
    /// In-place forward transform. `count` must be a power of two.
    static func forward(real: inout [Double], imag: inout [Double]) {
        let n = real.count
        precondition(n == imag.count)
        precondition(n > 0 && (n & (n - 1)) == 0, "FFT length must be a power of two")
        guard n > 1 else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 0 ..< (n - 1) {
            if i < j {
                real.swapAt(i, j); imag.swapAt(i, j)
            }
            var k = n >> 1
            while k <= j { j -= k; k >>= 1 }
            j += k
        }

        var len = 2
        while len <= n {
            let angle = -2.0 * Double.pi / Double(len)
            let wr = cos(angle), wi = sin(angle)
            var i = 0
            while i < n {
                var curR = 1.0, curI = 0.0
                for k in 0 ..< (len / 2) {
                    let aR = real[i + k], aI = imag[i + k]
                    let bR = real[i + k + len / 2], bI = imag[i + k + len / 2]
                    let tR = bR * curR - bI * curI
                    let tI = bR * curI + bI * curR
                    real[i + k] = aR + tR; imag[i + k] = aI + tI
                    real[i + k + len / 2] = aR - tR; imag[i + k + len / 2] = aI - tI
                    let nextR = curR * wr - curI * wi
                    curI = curR * wi + curI * wr
                    curR = nextR
                }
                i += len
            }
            len <<= 1
        }
    }

    static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}

/// Natural cubic spline, used to put an unevenly sampled RR tachogram onto a regular grid
/// for the Welch route. The Lomb–Scargle route needs none of this.
enum CubicSpline {
    static func interpolate(x: [Double], y: [Double], at targets: [Double]) -> [Double] {
        let n = x.count
        precondition(n == y.count)
        guard n >= 3 else {
            // Fall back to linear for degenerate inputs.
            return targets.map { t in linear(x: x, y: y, at: t) }
        }
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< n - 1 { h[i] = x[i + 1] - x[i] }

        var alpha = [Double](repeating: 0, count: n)
        for i in 1 ..< n - 1 {
            alpha[i] = 3 * ((y[i + 1] - y[i]) / h[i] - (y[i] - y[i - 1]) / h[i - 1])
        }
        var l = [Double](repeating: 0, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)
        l[0] = 1
        for i in 1 ..< n - 1 {
            l[i] = 2 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1]
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }
        l[n - 1] = 1
        var c = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n - 1)
        var d = [Double](repeating: 0, count: n - 1)
        for jj in stride(from: n - 2, through: 0, by: -1) {
            c[jj] = z[jj] - mu[jj] * c[jj + 1]
            b[jj] = (y[jj + 1] - y[jj]) / h[jj] - h[jj] * (c[jj + 1] + 2 * c[jj]) / 3
            d[jj] = (c[jj + 1] - c[jj]) / (3 * h[jj])
        }

        return targets.map { t in
            if t <= x[0] { return y[0] }
            if t >= x[n - 1] { return y[n - 1] }
            var lo = 0, hi = n - 2
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if x[mid] <= t { lo = mid } else { hi = mid - 1 }
            }
            let dx = t - x[lo]
            return y[lo] + b[lo] * dx + c[lo] * dx * dx + d[lo] * dx * dx * dx
        }
    }

    static func linear(x: [Double], y: [Double], at t: Double) -> Double {
        guard let first = x.first, let last = x.last else { return .nan }
        if t <= first { return y[0] }
        if t >= last { return y[y.count - 1] }
        for i in 0 ..< x.count - 1 where t >= x[i] && t <= x[i + 1] {
            let f = (t - x[i]) / (x[i + 1] - x[i])
            return y[i] + f * (y[i + 1] - y[i])
        }
        return y[y.count - 1]
    }
}
