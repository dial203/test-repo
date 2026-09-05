# Nocturne

An iOS + watchOS app that reads Apple Watch beat-to-beat interval data from HealthKit and
computes overnight HRV — RMSSD first, with the rest of the standard index set alongside it.

**Read this before you build anything on top of it.** The hard constraint on this whole
category of app is the data source, not the maths:

- Apple Watch does **not** expose live beat-to-beat intervals, or raw PPG, to third-party
  apps under any circumstances. There is no entitlement, no workout-session trick, no
  private-but-tolerated API.
- The one route to genuine inter-beat timing is `HKHeartbeatSeriesSample`: the beat
  timestamps that back each of the watch's own background HRV measurements. Those are
  readable with ordinary HealthKit authorization.
- The watch records them **opportunistically** — roughly a handful of ~60 s windows a
  night, not a continuous series. So an overnight file is a few short epochs, and every
  design decision downstream follows from that.
- Apple's own HRV metric is **SDNN over ~60 s**, which is not a Task Force 5-minute SDNN
  and is not interchangeable with the RMSSD that Oura, WHOOP and Fitbit report.

What that means in practice: RMSSD and the other successive-difference indices are
computable and defensible from passive watch data. LF power, VLF power, LF/HF and DFA α1
are not — the windows are too short — and this app declines to report them rather than
emitting a number that cannot mean what a reader would assume. If you need a dense,
continuous overnight RR series, it has to come from a chest strap; there is a Bluetooth
recorder built in for exactly that.

## Layout

```
Sources/HRVKit/        Analysis core. No HealthKit, no UIKit, no Apple-only APIs.
Tests/HRVKitTests/     57 tests, validated against analytic anchors.
Apps/Shared/           HealthKit reads, BLE recorder, night-building pipeline.
Apps/Nocturne/         iOS app (SwiftUI + SwiftData + Swift Charts).
Apps/NocturneWatch/    watchOS companion.
docs/METHODS.md        What the app computes and what it refuses to.
project.yml            XcodeGen spec — the Xcode project is generated, not committed.
```

`HRVKit` is deliberately free of Apple-only dependencies, so the analysis is testable
without a Mac and the correctness gate in CI runs on Linux.

## Build

```sh
make test                      # HRVKit test suite — macOS or Linux, no Xcode needed
brew install xcodegen
make open                      # generate Nocturne.xcodeproj and open it
```

Set your development team in Xcode's Signing & Capabilities, then run on a device.
HealthKit does not work in the Simulator for heartbeat series.

Required capabilities, already declared in `project.yml`:

| Capability | Why |
|---|---|
| HealthKit | reading heartbeat series, sleep and heart rate |
| HealthKit background delivery | analysing a night without the app being opened |
| Background Modes → Uses Bluetooth LE accessories | overnight chest-strap recording |

ECG voltage data would additionally need `com.apple.developer.healthkit.access` with
`electrocardiograms`, which Apple grants by request. This app does not use it.

## What the analysis does

Preprocessing, in order:

1. **Segment at gaps.** A beat the sensor flagged `precededByGap` breaks the series. So
   does any interval over 3000 ms. Successive differences are pooled across segments but
   never taken *through* one — concatenating gap-separated runs and differencing the
   joined array is the usual silent source of inflated RMSSD, and there is a test that
   pins the behaviour.
2. **Range gate.** Intervals outside 300–2000 ms are treated as missing data and split
   the segment, rather than being replaced with an interpolated value.
3. **Adaptive artifact correction** after Lipponen & Tarvainen (2019): time-varying
   thresholds from the quartile deviation of the dRR and mRR distributions, four-way beat
   classification (ectopic / missed / extra / long-short), class-specific correction. Two
   deliberate additions to the published algorithm are documented in `docs/METHODS.md`.
4. **Quality accounting.** The corrected fraction is carried on every window, never
   hidden. Windows above the ceiling (5% by default) are excluded from the nightly value
   but stay visible in the UI and in the export.

Indices: RMSSD, ln RMSSD, SDNN, SDSD, pNN50, pNN20, SD1, SD2, HRV triangular index per
window; Lomb–Scargle and interpolated-Welch spectra where the record is long enough;
DFA α1/α2 and sample entropy where there are enough beats.

Nightly aggregation: the headline value is the **median across retained windows**, and the
mean, 20% trimmed mean, deep-sleep-only, first-30/60/240-min and last-hour variants are
computed and exported next to it. These disagree by more than most people expect on a
night with any drift, so the choice is exposed rather than baked in.

Baselines use ln RMSSD with bands at the 60-night mean ± the smallest worthwhile change
(0.5 × between-night SD), plus the 7-night rolling mean and CV.

## Export

Everything, at four levels of granularity: raw beat timestamps with their gap flags,
corrected NN intervals tagged by segment, per-window indices, per-night summaries with
every alternative aggregation. CSV and JSON. Nothing leaves the device unless you export it.

## Validation

`make test` runs 57 tests. The ones that matter are anchored to values that can be derived
independently rather than to whatever the code happened to produce:

- Lomb–Scargle band power recovers the variance of a known sinusoid (Parseval), so band
  powers in ms² mean what a reader assumes.
- The FFT matches a naive DFT to 1e-9.
- DFA returns α ≈ 0.5 on white noise and α ≈ 1.5 on a random walk.
- Cubic spline reproduces a cubic exactly.
- Synthetic missed, extra and ectopic beats are each detected and RMSSD recovers to within
  10% of the uncorrupted value, while the uncorrected series is inflated by ~30% from a
  *single* artifact in 400 beats.
- The false-positive rate of the corrector on clean data is under 1%.

None of that validates the app against a criterion measure on real people. If you want
that, record a chest strap through the built-in BLE recorder alongside the watch and
compare the exports — the data comes out in a shape you can put straight into an
agreement analysis.

## Licence

MIT. See `LICENSE`.
