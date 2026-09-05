import SwiftUI
import UIKit
import HRVKit

/// What the app actually does, in the terms a methods section needs — and, more
/// importantly, what it cannot do. Every limitation here is a property of the data source,
/// not of this implementation.
struct MethodsView: View {
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Where the intervals come from") {
                    Text("""
                        Beat-to-beat intervals are read from HKHeartbeatSeriesSample, the only \
                        Apple Watch source of true inter-beat timing available to a third-party \
                        app. The watch records these opportunistically alongside its background \
                        HRV measurements, typically as ~60 s windows a few times a night, so an \
                        overnight file is a handful of short windows rather than a continuous \
                        series.
                        """)
                    Text("""
                        These are pulse-to-pulse intervals from a wrist PPG, not RR intervals \
                        from an ECG. Pulse transit time varies with posture, temperature and \
                        blood pressure, so PPG-derived RMSSD is systematically noisier than \
                        ECG RMSSD and the difference is not constant across the night.
                        """)
                }

                Section("Preprocessing") {
                    bullet("Beats flagged precededByGap by the sensor break the series; no successive difference is ever taken across a gap.")
                    bullet("Intervals outside 300–2000 ms are treated as missing data and split the segment rather than being interpolated.")
                    bullet("Adaptive artifact detection follows Lipponen & Tarvainen (2019): time-varying thresholds from the quartile deviation of the dRR and mRR distributions, with beats classified as ectopic, missed, extra or long/short and corrected accordingly.")
                    bullet("The corrected fraction is reported for every window. Windows above the ceiling (5% by default) are excluded from the nightly value but stay visible.")
                }

                Section("Indices") {
                    bullet("RMSSD, SDNN, SDSD, pNN50, pNN20, SD1, SD2 and the HRV triangular index are computed per window.")
                    bullet("The nightly value is the median across retained windows. Alternative aggregations — mean, 20% trimmed mean, deep-sleep only, first 30/60/240 min after onset, last hour before waking — are computed and exported alongside it.")
                    bullet("Baselines use ln RMSSD. Bands are the 60-night mean ± the smallest worthwhile change (0.5 × the between-night SD).")
                }

                Section("What this app will not report") {
                    bullet("LF power, VLF power and LF/HF from a 60 s window. A band is only reported when the record holds four full cycles of its lowest frequency, which needs ~100 s for LF and ~20 min for VLF.")
                    bullet("DFA α1 from short windows. It needs at least 200 beats.")
                    bullet("A 5-minute SDNN from Apple's data. Apple's own SDNN is computed over roughly 60 s and is not comparable to a Task Force 5-minute SDNN.")
                }

                Section {
                    Text(methodsParagraph).font(.footnote).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy methods paragraph") {
                        UIPasteboard.general.string = methodsParagraph
                        copied = true
                    }
                } header: {
                    Text("For a methods section")
                } footer: {
                    Text("Fill in the bracketed values from the Data tab before using this.")
                }

                Section("References") {
                    reference("Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology. Heart rate variability: standards of measurement, physiological interpretation, and clinical use. Circulation 1996;93:1043–1065.",
                              "https://doi.org/10.1161/01.CIR.93.5.1043")
                    reference("Lipponen JA, Tarvainen MP. A robust algorithm for heart rate variability time series artefact correction using novel beat classification. J Med Eng Technol 2019;43(3):173–181.",
                              "https://doi.org/10.1080/03091902.2019.1640306")
                    reference("Plews DJ, Laursen PB, Kilding AE, Buchheit M. Heart rate variability in elite triathletes: is variation in variability the key to effective training? A case comparison. Eur J Appl Physiol 2012;112:3729–3741.",
                              "https://doi.org/10.1007/s00421-012-2354-4")
                    reference("Laguna P, Moody GB, Mark RG. Power spectral density of unevenly sampled data by least-square analysis. IEEE Trans Biomed Eng 1998;45(6):698–715.",
                              "https://doi.org/10.1109/10.678605")
                }

                Section("Privacy") {
                    Text("""
                        Health data stays on this device. Nothing is uploaded, there is no \
                        account, and exports go only where you send them.
                        """)
                }
            }
            .navigationTitle("Methods")
        }
    }

    private var methodsParagraph: String {
        """
        Overnight cardiac autonomic activity was estimated from beat-to-beat intervals \
        recorded by an Apple Watch [model] and retrieved from HealthKit as heartbeat series \
        samples. Intervals were segmented at sensor-reported detection gaps and at intervals \
        outside 300–2000 ms, and artifacts were identified and corrected using the adaptive \
        threshold and beat classification scheme of Lipponen and Tarvainen (2019) as \
        reimplemented in HRVKit. Windows with more than 5% corrected beats were excluded. \
        Root mean square of successive differences (RMSSD) was computed within each retained \
        window, taking successive differences only within gap-free segments, and the nightly \
        value was taken as the median across windows. Values were log-transformed (ln RMSSD) \
        for analysis. Across [n] nights, median coverage was [x] min per night from [k] \
        windows, with a median corrected-beat fraction of [y]%. Because the intervals are \
        pulse-to-pulse intervals derived from wrist photoplethysmography rather than \
        ECG-derived RR intervals, absolute values are not interchangeable with ECG-derived \
        HRV, and frequency-domain indices were not computed because the available windows \
        were too short to resolve the low-frequency band.
        """
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
        }
    }

    private func reference(_ text: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.footnote)
            Link(url, destination: URL(string: url)!).font(.caption)
        }
    }
}
