# Methods

What Nocturne computes, how, and — the part that matters most for this data source —
what it declines to compute.

---

## 1. Data source and its limits

### 1.1 What Apple Watch actually exposes

| Source | Type | Content | Availability |
|---|---|---|---|
| `HKHeartbeatSeriesSample` | series | beat timestamps + `precededByGap` flags | opportunistic, ~60 s windows, a few per night |
| `heartRateVariabilitySDNN` | quantity | Apple's SDNN over the matching window | one per heartbeat series |
| `heartRate` | quantity | 5-beat-averaged HR | every few minutes at rest, ~1 Hz in a workout |
| `sleepAnalysis` | category | `inBed`, `awake`, `asleepCore/Deep/REM/Unspecified` | when sleep tracking is on |
| `HKElectrocardiogram` | sample | 30 s lead-I at 512 Hz | user-initiated only; needs the `electrocardiograms` entitlement |

`HKHeartbeatSeriesSample` is the only source of genuine inter-beat timing available to a
third-party app, and it is readable with ordinary HealthKit authorization — no special
entitlement. There is **no** API, entitlement or workout-session configuration that gives
a third-party app live beat-to-beat intervals or raw PPG from the watch's own sensor.
`HKHeartbeatSeriesBuilder` exists so an app can *write* series it obtained elsewhere —
from an external sensor — not to read the watch's.

Two consequences follow, and they shape everything below:

1. **Sparse coverage.** A night yields a handful of ~60 s epochs, not a continuous
   tachogram. Roughly 55–65 intervals per window.
2. **Pulse, not ECG.** These are pulse-to-pulse intervals from wrist photoplethysmography.
   Pulse transit time varies with posture, skin temperature and blood pressure, so
   PPG-derived RMSSD is noisier than ECG RMSSD and the discrepancy is not a constant
   offset across a night. Report them as PPI-derived, not as RR.

### 1.2 Apple's own SDNN is not a Task Force SDNN

Apple's native HRV metric is SDNN computed over roughly 60 s. SDNN is strongly
record-length dependent — a 24 h SDNN and a 5 min SDNN are different quantities with the
same name — so Apple's number is neither a Task Force 5-minute SDNN nor comparable to the
RMSSD that Oura, WHOOP and Fitbit report. Nocturne surfaces Apple's SDNN alongside its own
SDNN **for the same beats**, so any difference is visibly a processing difference rather
than a physiological one.

### 1.3 Getting a dense series

If you need continuous overnight RR — for five-minute-window analysis, for frequency-domain
indices, or as a criterion measure — it has to come from a sensor that reports RR intervals
over the Bluetooth Heart Rate Service (0x180D / 0x2A37). Polar H10, Garmin HRM-Pro and
Movesense all do. Nocturne includes a recorder for exactly this: it parses the RR field,
accumulates a beat train, marks stream dropouts as gaps, and writes the result back into
HealthKit as `HKHeartbeatSeriesSample`s tagged with the strap as their `HKDevice`, so the
two sources stay separable downstream.

---

## 2. Preprocessing

Applied in this order, per source series.

### 2.1 Gap segmentation

A beat the sensor flagged `precededByGap` opens a new segment, as does any raw interval
over 3000 ms. Every successive-difference statistic (RMSSD, SDSD, pNN50, SD1, DFA) is
computed **within** segments and pooled across them, never taken through a boundary.

This is not a detail. Concatenating gap-separated runs and differencing the joined array
injects a spurious difference at each join, whose size is the step in mean interval across
the gap. In the test suite, splicing two runs with a 205 ms step inflates RMSSD by more
than 3×. `TimeDomainTests.testSuccessiveDifferencesDoNotCrossGaps` pins the behaviour.

### 2.2 Physiological range gate

Intervals outside 300–2000 ms (200–30 bpm) are treated as **missing data** and split the
segment, rather than being replaced by an interpolated value. An impossible interval means
the sensor lost the pulse, and interpolating across it fabricates variability that was
never measured.

The 2000 ms ceiling is deliberately generous. Nocturnal bradycardia in endurance-trained
people routinely reaches 35–40 bpm; a tighter ceiling silently deletes their real data.

### 2.3 Adaptive artifact correction

Lipponen & Tarvainen (2019). Thresholds are time-varying, derived from the quartile
deviation of the dRR and mRR distributions over a 91-beat sliding window and scaled by
α = 5.2; beats are classified as ectopic, missed, extra or long/short using the published
subspace decision rules (c₁ = 0.13, c₂ = 0.17); correction is class-specific — extra beats
deleted, missed beats split, misaligned beats moved to the midpoint of their neighbours.
Detection is iterated until the artifact count stops falling, to a maximum of five passes.

This is an independent Swift port following the open reference implementation in NeuroKit2
(`signal_fixpeaks`, method `"kubios"`). It is **not** the Kubios binary and has not been
compared to it beat-for-beat. Describe it as a reimplementation of the published algorithm.

**Two deliberate deviations from the published algorithm**, both defensive and both
documented in the source:

1. **Absolute threshold floor (20 ms).** Every threshold is proportional to a quartile
   deviation. If that dispersion collapses toward zero, the normalised dRR series explodes.
   On real data α × QD is an order of magnitude above 20 ms and the floor never binds.
2. **Degenerate-dispersion guard.** If QD(|dRR|) / median(|dRR|) < 0.10, correction is
   skipped entirely and the fact is reported. For a half-normal |dRR| distribution — what
   real beat-to-beat data looks like — that ratio is about 0.62, so the guard only fires on
   genuinely degenerate input. Without it, a near-metronomic beat train is reported as
   >90% artifact. `ArtifactTests.testGuardDoesNotFireOnRealisticData` checks it stays quiet
   across twenty noisy synthetic tachograms.

### 2.4 Quality accounting

The corrected fraction is carried on every window and never hidden. Windows above the
ceiling (5% by default, the Kubios convention) are excluded from the nightly value but
remain visible in the UI and in the export.

One caveat specific to this data source: on a ~55-beat window, **three** corrected beats
already exceeds 5%. The ceiling was written for longer records, and with 60 s windows it
is a coarse instrument. The ceiling is adjustable, every night can be re-analysed under a
different setting without refetching, and the underlying counts are exported so you can
apply your own rule.

---

## 3. Indices

### 3.1 Time domain

RMSSD, ln RMSSD, SDNN, SDSD, pNN50, pNN20, mean and median NN, mean HR, SD1, SD2, SD2/SD1,
HRV triangular index (7.8125 ms bins). Sample (n−1) denominators throughout.

Identities the tests enforce: SD1² = SDSD²/2 and SD1² + SD2² = 2·SDNN².

### 3.2 Frequency domain

Two estimators, both available:

- **Lomb–Scargle** on the unevenly sampled tachogram. The default, because it needs no
  resampling and tolerates the gaps PPG data is full of. The periodogram is scaled by
  2·T/N so integrating the PSD recovers the series variance — band powers are therefore in
  ms² and mean what a reader assumes. `SpectralTests.testLombScarglePowerRecoversSineVariance`
  checks this against a sinusoid of known amplitude.
- **Cubic-spline resampling at 4 Hz + Welch** (Hann, 50% overlap, per-segment linear
  detrend), for comparability with the bulk of the published literature.

Bands: VLF 0.0033–0.04, LF 0.04–0.15, HF 0.15–0.40 Hz.

**A band is only reported when the record holds at least four full cycles of its lowest
frequency.** That means ~27 s for HF, ~100 s for LF and ~20 min for VLF. On a 60 s Apple
Watch window, HF comes back and LF, VLF and LF/HF come back as `NaN` with the unresolved
bands named. This is the single most consequential design decision in the library: a
number computed from less than one cycle of the band it claims to measure is worse than no
number, because it looks usable.

Frequency-domain analysis is therefore **off by default**. Turn it on when you are
analysing chest-strap data.

Two further cautions if you do use it. HF power is confounded by respiratory rate and
tidal volume; without a respiration channel, HF is not a clean vagal index, and the app
reads the watch's respiratory rate estimate for context but does not adjust for it.
LF/HF as "sympathovagal balance" has been repeatedly criticised and is reported here only
because reviewers ask for it.

### 3.3 Nonlinear

DFA α1 (n = 4–16) and α2 (n = 16–64), sample entropy (m = 2, r = 0.2 × SDNN). Both are
computed on the **longest gap-free run**, not on pooled segments.

DFA returns `NaN` below 200 beats. Sample entropy decimates records over 5000 beats to a
contiguous central window (it is O(N²)).

Validated against the two analytic anchors: α ≈ 0.5 on white noise, α ≈ 1.5 on a random
walk.

---

## 4. Nightly aggregation

Windows are attributed to a sleep stage by the stage covering most of their duration, and
— when staging exists — analysis is restricted to sleep onset → final awakening.

The headline nightly value is the **median of per-window RMSSD across retained windows**.
Median rather than mean because per-window RMSSD is right-skewed and one
motion-contaminated window moves a mean substantially.

There is no consensus rule here, and different products use different ones, so Nocturne
computes and exports the alternatives beside the headline:

| Key | Rule |
|---|---|
| `rmssd.median` | median of all retained windows (headline) |
| `rmssd.mean` | arithmetic mean |
| `rmssd.trimmedMean20` | 20% trimmed mean |
| `rmssd.deep` / `.core` / `.rem` | median within one stage |
| `rmssd.first30min` / `first60min` / `first240min` | windows starting within N min of sleep onset |
| `rmssd.last60min` | windows in the last hour before final awakening |
| `lnRMSSD.medianOfLogs` | median of per-window ln RMSSD |

These disagree by more than most people expect. On a synthetic night with a monotone rise
in RSA amplitude, the last-hour value exceeds the first-30-minute value by over 20%. If you
are comparing to a published protocol, pick the matching rule explicitly rather than
inheriting a default.

`nightOf` labels a night by the evening it began: anything before noon is attributed to the
previous calendar day. The search window for night *D* is 18:00 on *D* to 12:00 on *D+1*.

When several sources have written overlapping sleep for one night, the single source
contributing the most staged time is used; mixing sources produces impossible staging.

---

## 5. Baselines

On ln RMSSD, which is approximately normal and the appropriate form for parametric work.

- 7-night rolling mean and CV (SD as a percentage of the mean).
- 60-night mean and SD as the reference distribution.
- **Smallest worthwhile change = 0.5 × the 60-night SD.** Tonight is flagged below or above
  normal when it falls outside mean ± SWC.
- z relative to the 60-night distribution.
- No banding at all below 14 nights.

Tonight is excluded from its own reference distribution.

This is change detection on a single-subject time series. It is not validated against any
outcome, and the bands are a convention, not a decision rule. The pattern Plews et al.
describe — a falling rolling mean *with* a rising CV — is the one worth looking at, and
neither component means much alone.

---

## 6. Export

| File | Grain |
|---|---|
| beats | one row per beat: series id, offset, absolute time, gap flag, source, device |
| intervals | one row per corrected NN, tagged with its segment index |
| windows | one row per analysis window: every index, stage, artifact fraction, quality flag |
| nights | one row per night: headline values, coverage, sleep, every alternative aggregation |
| JSON | the complete object graph, raw beats included |

The beat-level export is the point: it lets the whole analysis be reproduced in R, Python
or Kubios, and it is the input an agreement analysis needs.

---

## 7. Validation status

The test suite (`make test`, 57 tests) validates the **implementation** against values
derivable independently of the code:

| Check | Anchor |
|---|---|
| RMSSD, SDNN, pNN50, triangular index | hand-computed from small arrays |
| Poincaré | SD1² = SDSD²/2, SD1² + SD2² = 2·SDNN² |
| FFT | naive DFT to 1e-9 |
| Cubic spline | exact on a cubic polynomial |
| Lomb–Scargle | band power = A²/2 for a sinusoid of amplitude A |
| Welch vs Lomb–Scargle | within 30% on a clean signal |
| DFA | 0.5 on white noise, 1.5 on a random walk |
| Sample entropy | near zero for a periodic series, >1.5 for noise |
| Artifact correction | synthetic missed/extra/ectopic beats detected; RMSSD recovered to within 10% |
| Corrector specificity | <1% false positives on clean synthetic data |
| BLE parser | byte fixtures for 8/16-bit HR, energy, contact, truncation |

**None of this is criterion validation.** Nothing here establishes agreement between
Apple Watch PPI-derived RMSSD and an ECG reference in real people. If you want that, the
built-in BLE recorder lets you capture a chest strap simultaneously and export both;
analyse the pair with Bland–Altman limits of agreement, CCC, RMSE and an equivalence test
against a pre-specified bound. Correlation alone will not answer the question and a
reviewer will say so.

One measured number worth knowing before you plan a study: in the synthetic tests, a
**single** artifact in 400 beats inflates uncorrected RMSSD by roughly 30%. Artifact
handling is not a refinement in this data — it dominates.

---

## References

All links verified against CrossRef.

- Task Force of the European Society of Cardiology and the North American Society of Pacing
  and Electrophysiology. Heart rate variability: standards of measurement, physiological
  interpretation, and clinical use. *Circulation* 1996;93(5):1043–1065.
  https://doi.org/10.1161/01.CIR.93.5.1043
- Lipponen JA, Tarvainen MP. A robust algorithm for heart rate variability time series
  artefact correction using novel beat classification. *J Med Eng Technol*
  2019;43(3):173–181. https://doi.org/10.1080/03091902.2019.1640306
- Shaffer F, Ginsberg JP. An overview of heart rate variability metrics and norms.
  *Front Public Health* 2017;5:258. https://doi.org/10.3389/fpubh.2017.00258
- Lomb NR. Least-squares frequency analysis of unequally spaced data. *Astrophys Space Sci*
  1976;39:447–462. https://doi.org/10.1007/BF00648343
- Scargle JD. Studies in astronomical time series analysis. II. Statistical aspects of
  spectral analysis of unevenly spaced data. *Astrophys J* 1982;263:835.
  https://doi.org/10.1086/160554
- Laguna P, Moody GB, Mark RG. Power spectral density of unevenly sampled data by
  least-square analysis: performance and application to heart rate signals.
  *IEEE Trans Biomed Eng* 1998;45(6):698–715. https://doi.org/10.1109/10.678605
- Peng C-K, Havlin S, Stanley HE, Goldberger AL. Quantification of scaling exponents and
  crossover phenomena in nonstationary heartbeat time series. *Chaos* 1995;5(1):82–87.
  https://doi.org/10.1063/1.166141
- Richman JS, Moorman JR. Physiological time-series analysis using approximate entropy and
  sample entropy. *Am J Physiol Heart Circ Physiol* 2000;278(6):H2039–H2049.
  https://doi.org/10.1152/ajpheart.2000.278.6.H2039
- Plews DJ, Laursen PB, Kilding AE, Buchheit M. Heart rate variability in elite triathletes,
  is variation in variability the key to effective training? A case comparison.
  *Eur J Appl Physiol* 2012;112(11):3729–3741. https://doi.org/10.1007/s00421-012-2354-4
- Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart
  rate variability in elite endurance athletes: opening the door to effective monitoring.
  *Sports Med* 2013;43(9):773–781. https://doi.org/10.1007/s40279-013-0071-8
- Hernando D, Roca S, Sancho J, Alesanco Á, Bailón R. Validation of the Apple Watch for
  heart rate variability measurements during relax and mental stress in healthy subjects.
  *Sensors* 2018;18(8):2619. https://doi.org/10.3390/s18082619
- O'Grady B, Lambe R, Baldwin M, Acheson T, Doherty C. The validity of Apple Watch Series 9 and Ultra 2 for serial
  measurements of heart rate variability and resting heart rate. *Sensors* 2024;24(19):6220.
  https://doi.org/10.3390/s24196220

Software reference for the artifact-correction port:

- Makowski D, et al. NeuroKit2: a Python toolbox for neurophysiological signal processing.
  *Behav Res Methods* 2021;53:1689–1696. https://doi.org/10.3758/s13428-020-01516-y
