import Foundation

/// Spectral bands, Task Force (1996) short-term definitions.
public struct FrequencyBands: Sendable, Hashable, Codable {
    public var vlf: ClosedRange<Double> = 0.0033 ... 0.04
    public var lf: ClosedRange<Double> = 0.04 ... 0.15
    public var hf: ClosedRange<Double> = 0.15 ... 0.40
    public init() {}

    /// Widened HF ceiling for populations whose respiratory rate exceeds 24 breaths/min.
    /// Do not use this for adults at rest without saying so.
    public static var widerHF: FrequencyBands {
        var b = FrequencyBands(); b.hf = 0.15 ... 0.50; return b
    }
}

public enum SpectralMethod: Sendable, Hashable, Codable {
    /// Lomb–Scargle periodogram computed directly on the unevenly sampled tachogram.
    /// Preferred here: no resampling, and it tolerates the gaps that PPG data is full of.
    case lombScargle(oversampling: Double = 4.0)
    /// Cubic-spline resampling onto a regular grid followed by Welch's method.
    /// Included for comparability with the bulk of the published literature.
    case interpolatedWelch(resampleHz: Double = 4.0, segmentSeconds: Double = 256.0, overlap: Double = 0.5)
}

public struct FrequencyDomainMetrics: Sendable, Hashable, Codable {
    public let method: SpectralMethod
    /// Absolute band powers, ms².
    public let vlfPower: Double
    public let lfPower: Double
    public let hfPower: Double
    /// Power over VLF+LF+HF, ms².
    public let totalPower: Double
    /// Normalised units: LF / (LF + HF) × 100 and HF / (LF + HF) × 100.
    public let lfnu: Double
    public let hfnu: Double
    public let lfhfRatio: Double
    /// Frequency of maximum PSD within each band, Hz.
    public let vlfPeak: Double
    public let lfPeak: Double
    public let hfPeak: Double
    /// Length of the analysed record, seconds.
    public let duration: TimeInterval
    public let nnCount: Int
    /// Bands whose lowest frequency was not resolvable in a record this short; their
    /// powers are `NaN`. See `FrequencyDomain.minimumCyclesPerBand`.
    public let unresolvedBands: [String]
}

/// Why a spectral estimate was refused. Frequency-domain HRV has hard record-length
/// requirements and this library declines rather than returning a number that cannot mean
/// what the caller thinks it means.
public enum SpectralRefusal: String, Sendable, Codable, Error {
    case tooFewIntervals
    /// Shorter than the reciprocal of the lowest requested frequency, so the lowest band
    /// is unresolvable. VLF needs ≥ 5 min; the Task Force asks for 24 h to interpret it.
    case recordTooShortForLowestBand
    /// Welch needs at least two full segments.
    case tooShortForWelch
}

public enum FrequencyDomain {

    /// Full cycles of a band's lowest frequency that must fit inside the record before
    /// that band is reported. Task Force guidance is 5 min for LF/HF and 24 h before VLF
    /// is interpretable; this is the same idea expressed as a hard arithmetic floor.
    public static let minimumCyclesPerBand: Double = 4.0

    /// Estimate the RR tachogram spectrum for a single gap-free segment.
    ///
    /// Segments are analysed individually and never concatenated: splicing gap-separated
    /// runs together injects a step discontinuity that lands squarely in the VLF and LF
    /// bands.
    public static func metrics(
        for segment: IntervalSegment,
        method: SpectralMethod = .lombScargle(),
        bands: FrequencyBands = FrequencyBands(),
        detrend: Bool = true
    ) -> Result<FrequencyDomainMetrics, SpectralRefusal> {
        let nn = segment.intervals
        guard nn.count >= 20 else { return .failure(.tooFewIntervals) }

        // Place each NN at the time of the R peak that closes it.
        var t = [Double](); t.reserveCapacity(nn.count)
        var acc = 0.0
        for v in nn { acc += v / 1000.0; t.append(acc) }
        let duration = acc

        // A band is only reported when the record holds at least `minimumCyclesPerBand`
        // full cycles of its lowest frequency. With the default of 4 that means HF needs
        // ~27 s, LF ~100 s and VLF ~20 min. Anything shorter comes back as NaN rather
        // than as a number computed from less than a cycle of data.
        func resolvable(_ range: ClosedRange<Double>) -> Bool {
            range.lowerBound <= 0 || duration >= minimumCyclesPerBand / range.lowerBound
        }
        let vlfOK = resolvable(bands.vlf), lfOK = resolvable(bands.lf), hfOK = resolvable(bands.hf)
        guard hfOK else { return .failure(.recordTooShortForLowestBand) }

        var y = nn
        if detrend {
            let fit = Stats.linearFit(x: t, y: y)
            if fit.slope.isFinite { for i in y.indices { y[i] -= (fit.slope * t[i] + fit.intercept) } }
        }

        let psd: (freqs: [Double], power: [Double])
        switch method {
        case let .lombScargle(oversampling):
            psd = lombScarglePSD(t: t, y: y, oversampling: oversampling,
                                 maxFrequency: bands.hf.upperBound * 1.25)
        case let .interpolatedWelch(fs, segSeconds, overlap):
            let needed = segSeconds * (1 + (1 - overlap))
            guard duration >= needed else { return .failure(.tooShortForWelch) }
            psd = welchPSD(t: t, y: y, fs: fs, segmentSeconds: segSeconds, overlap: overlap)
        }

        func bandPower(_ range: ClosedRange<Double>) -> (power: Double, peak: Double) {
            var p = 0.0, best = -Double.infinity, peak = Double.nan
            guard psd.freqs.count > 1 else { return (.nan, .nan) }
            let df = psd.freqs[1] - psd.freqs[0]
            for (i, f) in psd.freqs.enumerated() where range.contains(f) {
                p += psd.power[i] * df
                if psd.power[i] > best { best = psd.power[i]; peak = f }
            }
            return (p, peak)
        }

        let vlf = vlfOK ? bandPower(bands.vlf) : (power: Double.nan, peak: Double.nan)
        let lf = lfOK ? bandPower(bands.lf) : (power: Double.nan, peak: Double.nan)
        let hf = bandPower(bands.hf)
        let lfhfSum = lf.power + hf.power
        var unresolved: [String] = []
        if !vlfOK { unresolved.append("VLF") }
        if !lfOK { unresolved.append("LF") }

        return .success(FrequencyDomainMetrics(
            method: method,
            vlfPower: vlf.power,
            lfPower: lf.power,
            hfPower: hf.power,
            totalPower: [vlf.power, lf.power, hf.power].filter(\.isFinite).reduce(0, +),
            lfnu: lfhfSum > 0 ? 100 * lf.power / lfhfSum : .nan,
            hfnu: lfhfSum > 0 ? 100 * hf.power / lfhfSum : .nan,
            lfhfRatio: hf.power > 0 ? lf.power / hf.power : .nan,
            vlfPeak: vlf.peak, lfPeak: lf.peak, hfPeak: hf.peak,
            duration: duration,
            nnCount: nn.count,
            unresolvedBands: unresolved
        ))
    }

    // MARK: - Lomb–Scargle

    /// One-sided PSD estimate in units²/Hz from the classical Lomb–Scargle periodogram.
    ///
    /// The periodogram is scaled by `2·T/N` so that integrating it over frequency
    /// recovers the series variance — the same convention that makes band powers
    /// comparable with an FFT-based estimate.
    static func lombScarglePSD(
        t: [Double], y: [Double], oversampling: Double, maxFrequency: Double
    ) -> (freqs: [Double], power: [Double]) {
        let n = t.count
        guard n > 3, let first = t.first, let last = t.last, last > first else {
            return ([], [])
        }
        let T = last - first
        let df = 1.0 / (oversampling * T)
        let count = max(1, Int((maxFrequency / df).rounded(.down)))

        let mean = Stats.mean(y)
        let centred = y.map { $0 - mean }

        var freqs = [Double](repeating: 0, count: count)
        var power = [Double](repeating: 0, count: count)

        for k in 0 ..< count {
            let f = Double(k + 1) * df
            freqs[k] = f
            let w = 2.0 * Double.pi * f

            var s2 = 0.0, c2 = 0.0
            for ti in t { s2 += sin(2 * w * ti); c2 += cos(2 * w * ti) }
            let tau = atan2(s2, c2) / (2 * w)

            var cc = 0.0, ss = 0.0, yc = 0.0, ys = 0.0
            for i in 0 ..< n {
                let arg = w * (t[i] - tau)
                let cs = cos(arg), sn = sin(arg)
                cc += cs * cs
                ss += sn * sn
                yc += centred[i] * cs
                ys += centred[i] * sn
            }
            let pLomb = 0.5 * ((cc > 0 ? yc * yc / cc : 0) + (ss > 0 ? ys * ys / ss : 0))
            power[k] = 2.0 * (T / Double(n)) * pLomb
        }
        return (freqs, power)
    }

    // MARK: - Interpolated Welch

    static func welchPSD(
        t: [Double], y: [Double], fs: Double, segmentSeconds: Double, overlap: Double
    ) -> (freqs: [Double], power: [Double]) {
        guard let last = t.last, let first = t.first, last > first else { return ([], []) }
        let total = Int(((last - first) * fs).rounded(.down))
        guard total > 8 else { return ([], []) }
        let grid = (0 ..< total).map { first + Double($0) / fs }
        let resampled = CubicSpline.interpolate(x: t, y: y, at: grid)

        // Power-of-two segment so the radix-2 FFT applies with no zero padding.
        let requested = Int((segmentSeconds * fs).rounded())
        var nfft = FFT.nextPowerOfTwo(requested)
        if nfft > total { nfft = FFT.nextPowerOfTwo(total) / 2 }
        guard nfft >= 16 else { return ([], []) }
        let step = max(1, Int(Double(nfft) * (1 - overlap)))

        // Hann window.
        let window = (0 ..< nfft).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft - 1)) }
        let windowPower = window.reduce(0) { $0 + $1 * $1 }

        var accum = [Double](repeating: 0, count: nfft / 2 + 1)
        var segments = 0
        var startIdx = 0
        while startIdx + nfft <= resampled.count {
            var chunk = Array(resampled[startIdx ..< startIdx + nfft])
            // Per-segment linear detrend.
            let xs = (0 ..< nfft).map(Double.init)
            let fit = Stats.linearFit(x: xs, y: chunk)
            if fit.slope.isFinite { for i in chunk.indices { chunk[i] -= fit.slope * xs[i] + fit.intercept } }
            for i in chunk.indices { chunk[i] *= window[i] }

            var re = chunk
            var im = [Double](repeating: 0, count: nfft)
            FFT.forward(real: &re, imag: &im)
            for k in 0 ... nfft / 2 {
                let mag = re[k] * re[k] + im[k] * im[k]
                let oneSided = (k == 0 || k == nfft / 2) ? mag : 2 * mag
                accum[k] += oneSided / (fs * windowPower)
            }
            segments += 1
            startIdx += step
        }
        guard segments > 0 else { return ([], []) }
        let freqs = (0 ... nfft / 2).map { Double($0) * fs / Double(nfft) }
        return (freqs, accum.map { $0 / Double(segments) })
    }
}
