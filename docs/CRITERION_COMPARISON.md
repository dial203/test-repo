# Criterion comparison: Apple Watch against a chest strap

How to run an agreement analysis with `hrv-agreement`, and the three things that most
often make one meaningless.

## First: does your Polar data actually contain RR intervals?

Polar Flow's HRV export gives true beat-to-beat intervals, but **only for sessions
recorded by a Polar watch paired with an ECG sensor.** It is unavailable when:

- the session was recorded by the **Polar Beat app**, even with an H10;
- the session was recorded to the **H10's internal memory** and processed by Polar Beat;
- the heart rate came from an **optical** sensor.

Separately: **Polar Flow writes only steps, heart rate and workouts to Apple Health.** RR
intervals and HRV are not in the HealthKit integration, so the criterion data has to come
out of Polar Flow's web service, not out of Apple Health.

Check before anything else:

```sh
swift run hrv-agreement describe --reference night-01.csv
```

It prints the delimiter, which column it took, the units it inferred and the median raw
value. If it reports ~55 intervals for an eight-hour night, you exported heart rate
summaries rather than RR, and no analysis downstream can rescue that. If it reports tens of
thousands of intervals with a median near 1000 ms, you have the real thing.

Units are inferred, never guessed: 250–2500 ms and 0.25–2.5 s are accepted, and anything
else is refused rather than scaled. A silent factor-of-1000 error produces a perfectly
plausible RMSSD.

## Running the comparison

```sh
swift run hrv-agreement compare \
    --test watch-beats.csv \
    --reference polar-rr.csv \
    --metric rmssd \
    --bound 3 \
    --paired-out paired-epochs.csv
```

`--test` is the beat export from the app (`Export.beatsCSV`) or from the study server
(`/v1/participants/{code}/beats.csv`). `--reference` is the Polar RR CSV, or any RR file —
Kubios, HRV Logger, Polar Sensor Logger and single-column text all parse.

If the reference file has no timestamp column, pass `--reference-start` with the recording
start. Without absolute time there is nothing to align to.

## The three things that break these analyses

### 1. Comparing different quantities

Apple Watch gives ~60 s epochs at times you do not control. A chest strap gives a
continuous night. **RMSSD over eight hours is not RMSSD over one minute**, so comparing the
watch's window value against a whole-night strap value is not an agreement analysis — the
two numbers estimate different things and the disagreement is arithmetic, not
instrumental.

The aligner extracts the strap's beats over the *same wall-clock interval* as each watch
window, and takes only intervals wholly inside it so no successive difference is computed
against a beat outside the epoch. Epochs where the strap covered less than 90% of the
window are excluded and counted.

### 2. Clock offset

The watch and the strap's recorder keep independent clocks. An offset of tens of seconds
pairs each watch window against the wrong minute of the criterion record, and the analysis
reports poor agreement caused entirely by misalignment.

The offset is estimated from the data by cross-correlating heart rate against time across a
±120 s search, and the peak correlation is reported. **If that peak is below 0.5 the
estimate is not trustworthy** — the tool says so, applies no shift, and you should check
that the two recordings genuinely overlap before reading anything below it.

Heart rate rather than the RR series itself, because the two devices detect different
numbers of beats, so an index-wise correlation would be meaningless while the
heart-rate-versus-time curve is the same physiological signal in both.

### 3. Preprocessing asymmetry

If the watch's beats were artifact-corrected and the strap's were not, the measured
difference mixes device with pipeline and nothing downstream can separate them. Pass the
test-side configuration and the report confirms both sides match; the tool warns when they
do not.

## Reading the output

**Bland–Altman, clustered by night.** Many epochs from one night are not independent
observations. Pooling 230 epochs from 14 nights as if they were makes the confidence
interval on the bias about four times narrower than the data support, because the
information about bias lives in 14 nights, not 230 correlated epochs. The clustered form is
the default and reports the within- and between-night components separately.

**Proportional bias.** If the slope of difference on mean is significant, one pair of
limits misrepresents agreement across the range. For RMSSD this is the normal case — error
scales with magnitude — and the remedy is the ratio limits.

**Ratio limits.** Bland–Altman on logs, reported multiplicatively: "reads 9% high, with
individual values within −6% to +12%". These apply across the whole range rather than only
near the mean, which is why they are usually the right thing to report for HRV.

**Lin's CCC next to Pearson r.** The gap between them is the point. A tight linear
relationship with a systematic offset gives r = 0.96 and CCC = 0.39: excellent precision,
poor concordance. Reporting only the correlation would call that agreement. The CCC
interval comes from a cluster bootstrap, resampling whole nights, because Lin's closed-form
variance assumes independent observations.

**Equivalence (TOST).** Note the trap: a bias of 4.2 ms passes a ±5 ms bound. The bound
does the work, so it has to be pre-specified from something defensible — a smallest
worthwhile change, a published typical error, a difference that would change a decision —
and stated before the analysis. A bound chosen after seeing the data is not a test. Also,
failing equivalence is not the same as demonstrating a difference: with few nights the
interval is often simply too wide to decide, and the tool says which.

## What this can and cannot establish

Many nights from one person is a **within-subject** agreement analysis. It characterises
how these two devices agree on you, and it is the right basis for a power calculation. It
is not a population agreement study: between-subject variation in skin, wrist anatomy,
resting heart rate and sleep posture is exactly what determines whether the watch works for
a cohort, and one subject contributes nothing about it.

With that framing it is publishable and genuinely useful — an n-of-1 validation with
transparent methods and beat-level data is more than most consumer-wearable papers offer.
Frame the conclusion as within-subject, report the number of nights as the sample size for
the bias, and use the between-night component to power the cohort study.

## Sources

- [Polar: HRV data file export in the Flow Web Service](https://support.polar.com/en/hrv-data-export)
- [Polar: Downloadable RR-intervals from training sessions](https://www.polar.com/blog/downloadable-rr-intervals-from-training-sessions/)
- [Polar: Connecting Polar Beat with Apple Health](https://support.polar.com/us-en/connecting-polar-beat-with-apple-health)
- Bland JM, Altman DG. *Statistical methods for assessing agreement between two methods of clinical measurement.* Lancet 1986;327:307–310. https://doi.org/10.1016/S0140-6736(86)90837-8
- Bland JM, Altman DG. *Measuring agreement in method comparison studies.* Stat Methods Med Res 1999;8:135–160. https://doi.org/10.1177/096228029900800204
- Bland JM, Altman DG. *Agreement between methods of measurement with multiple observations per individual.* J Biopharm Stat 2007;17:571–582. https://doi.org/10.1080/10543400701329422
- Lin LI. *A concordance correlation coefficient to evaluate reproducibility.* Biometrics 1989;45:255–268. https://doi.org/10.2307/2532051
