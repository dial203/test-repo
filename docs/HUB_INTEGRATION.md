# Feeding an external hub

The narrow job: read Apple Health's beat-to-beat data, compute RMSSD, make it available
over HTTP for something else to pull. Nothing here computes anything about a criterion
device — that stays wherever it already lives.

## The pieces

```
Apple Watch ──► iPhone Health store ──► Nocturne iOS app
                                          │  HKHeartbeatSeriesSample -> RMSSD (HRVKit)
                                          ▼  POST /v1/ingest   (device token, write-only)
                                   nocturne-sync
                                          │
                                          ▼  GET /v1/metrics   (researcher token, read-only)
                                   your sleep validation hub
```

The iOS app is unavoidable: HealthKit is device-local, and heartbeat series are not in
Apple's own Health export either. Everything after it is replaceable.

## The feed to poll

```
GET /v1/metrics?participant=p014&from=2026-09-01&to=2026-09-30
Authorization: Bearer <researcher token>
```

```json
[{
  "participant_code": "p014",
  "night_of": "2026-09-07",
  "rmssd_ms": 47.2,
  "ln_rmssd": 3.854,
  "sdnn_ms": 61.3,
  "mean_hr_bpm": 52.1,
  "min_hr_bpm": 47.0,
  "pnn50_pct": 31.2,
  "sd1_ms": 33.4,
  "sd2_ms": 89.7,
  "aggregation": "median_of_windows",
  "window_count": 13,
  "coverage_s": 780.0,
  "artifact_fraction": 0.012,
  "quality": "good",
  "sources": ["com.apple.health"],
  "config_hash": "ad03842e11fa51a1",
  "hrvkit_version": "0.1.0",
  "analysed_at": "2026-09-08T12:00:00Z",
  "received_at": "2026-09-08T15:17:44Z",
  "revision_count": 1
}]
```

`GET /v1/metrics.csv` returns the same rows as CSV. Join on
`(participant_code, night_of)`.

### Fields a consumer has to handle

**`rmssd_ms` can be `null`.** A night with too few windows has no RMSSD, and that is a
real state rather than a zero. The analysis represents it as NaN internally and the Swift
client encodes non-finite doubles as the strings `"NaN"`/`"Infinity"`; both collapse to
`null` here, so nothing but a number or a null ever reaches you. Check `quality` —
`good`, `sparse` or `insufficient` — before using a value.

**`config_hash` identifies the preprocessing.** If it changes between two polls, the
number changed because the analysis settings changed, not because the participant did.
Store it next to the value; after the fact those two cases are otherwise indistinguishable.

**`revision_count > 1` means the night was analysed more than once.** By default this feed
returns only the most recently analysed revision. It never averages them. Add
`all_revisions=true` to see them all, or `config_hash=…` to pin one.

**`aggregation` is `median_of_windows`.** Apple records ~60 s heartbeat series a few times
a night, so `rmssd_ms` is the median of per-window RMSSD across the retained windows — not
a pooled whole-night value. The distinction matters: on a real overnight chest-strap file,
1.4% of successive differences carried 36% of the pooled RMSSD variance, so a pooled value
is largely a count of arousals. `window_count` and `coverage_s` say how much data stands
behind the number.

**`sources`** lists the HealthKit source identifiers that contributed beats.
`["com.apple.health"]` is the watch. An empty list means the uploading client did not
report them.

## Consider skipping this service entirely

If your hub already accepts inbound HTTP, it does not need to poll anything — point the
app at it and let it push. `NocturneServerURL` in `project.yml` is the only thing that
decides where uploads go, and the payload is documented in
[API.md](API.md#ingest). Your hub would need to accept `POST /v1/ingest` with a bearer
token and return the `IngestResult` shape, and then `server/` is dead weight.

That is one less thing to deploy, back up and keep patched. The reasons to keep this
service are if you want the participant enrolment flow, the write-only device tokens, the
audit log, or a staging store that survives your hub being down — not the metric feed
itself, which is thin.

## Read this before using `rmssd_ms` as a validation input

If your hub computes the H10's RMSSD with its own code and takes the watch's RMSSD from
this feed, the difference between them is **device plus pipeline**, and nothing downstream
can separate the two.

That is not hypothetical. This library's own artifact correction moved RMSSD by 7% on a
real overnight recording, and a defect found on that same file — the published
Lipponen–Tarvainen missed-beat test losing its discrimination on high-variability data —
had been fabricating 65 beats a night before it was fixed. Whatever your hub does will
differ from this in some comparable way.

So for agreement work, pull the beats and compute both sides with one implementation:

```
GET /v1/participants/p014/beats.csv?from=2026-09-07T18:00:00%2B00:00&to=2026-09-08T14:00:00%2B00:00
```

One row per beat, with the gap flags preserved. Feed it through the same code path as your
H10 RR and the pipeline term disappears. Then `rmssd_ms` is a convenience and a
cross-check, not the number a conclusion rests on.

Note the `%2B` — an unencoded `+` in an ISO offset arrives as a space. This API repairs
that case, but encoding it is better.

## Setup

```sh
make -C server install
nocturne-admin create-study OSU-HRV-2026 --name "Sleep validation" --retention-days 1095
nocturne-admin add-participants --study OSU-HRV-2026 --count 40 --prefix p
nocturne-admin mint-researcher-token --label "validation-hub" --study OSU-HRV-2026 --expires-days 365
```

The researcher token is the hub's credential. It is read-only and cannot ingest. Device
tokens are write-only and cannot read — including their own uploads.

`GET /docs` serves the generated OpenAPI UI; point a client generator at
`/openapi.json` rather than hand-writing request models.
