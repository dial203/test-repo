import Foundation

/// The handful of distribution functions the agreement statistics need.
///
/// Hand-rolled for the same reason as SHA-256: the analysis core stays free of
/// Apple-only frameworks and produces identical numbers on device and in Linux CI.
/// Validated against published critical values in the test suite.
public enum Distributions {

    // MARK: - Normal

    /// Standard normal quantile. Acklam's rational approximation, refined by one
    /// Halley step, giving roughly full double precision.
    public static func normalQuantile(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return p <= 0 ? -.infinity : .infinity }

        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let pLow = 0.02425, pHigh = 1 - pLow
        var x: Double

        if p < pLow {
            let q = (-2 * log(p)).squareRoot()
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= pHigh {
            let q = p - 0.5, r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
                / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }

        // One Halley refinement against the true CDF.
        let e = 0.5 * erfc(-x / 2.0.squareRoot()) - p
        let u = e * (2 * Double.pi).squareRoot() * exp(x * x / 2)
        return x - u / (1 + x * u / 2)
    }

    public static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    // MARK: - Student's t

    /// Two-sided t distribution CDF, via the regularised incomplete beta function.
    public static func tCDF(_ t: Double, df: Double) -> Double {
        guard df > 0 else { return .nan }
        let x = df / (df + t * t)
        let p = 0.5 * incompleteBeta(a: df / 2, b: 0.5, x: x)
        return t > 0 ? 1 - p : p
    }

    /// Two-tailed p-value for a t statistic.
    public static func tTwoTailedP(_ t: Double, df: Double) -> Double {
        guard df > 0 else { return .nan }
        let x = df / (df + t * t)
        return incompleteBeta(a: df / 2, b: 0.5, x: x)
    }

    /// Student's t quantile. Bisection on the CDF: slower than a closed form and
    /// completely reliable, which is the right trade for a few dozen calls.
    public static func tQuantile(_ p: Double, df: Double) -> Double {
        guard p > 0, p < 1, df > 0 else { return .nan }
        if p == 0.5 { return 0 }
        var lo = -1e3, hi = 1e3
        for _ in 0 ..< 200 {
            let mid = (lo + hi) / 2
            if tCDF(mid, df: df) < p { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: - Special functions

    /// Log gamma, Lanczos approximation.
    public static func logGamma(_ x: Double) -> Double {
        let coefficients = [76.18009172947146, -86.50532032941677, 24.01409824083091,
                            -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5]
        var y = x
        let tmp = x + 5.5 - (x + 0.5) * log(x + 5.5)
        var series = 1.000000000190015
        for c in coefficients { y += 1; series += c / y }
        return -tmp + log(2.5066282746310005 * series / x)
    }

    /// Regularised incomplete beta function I_x(a, b), by the continued fraction of
    /// Lentz as given in Numerical Recipes.
    public static func incompleteBeta(a: Double, b: Double, x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(logGamma(a + b) - logGamma(a) - logGamma(b)
            + a * log(x) + b * log(1 - x))
        // The continued fraction converges quickly only for x < (a+1)/(a+b+2); use the
        // symmetry relation otherwise.
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(a: a, b: b, x: x) / a
        }
        return 1 - exp(logGamma(a + b) - logGamma(a) - logGamma(b)
            + b * log(1 - x) + a * log(x)) * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
    }

    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let tiny = 1e-30
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d

        for m in 1 ... 300 {
            let mDouble = Double(m)
            let m2 = 2 * mDouble

            var aa = mDouble * (b - mDouble) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c

            aa = -(a + mDouble) * (qab + mDouble) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 3e-16 { break }
        }
        return h
    }
}
