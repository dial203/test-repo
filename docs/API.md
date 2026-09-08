# Sync API

Ingest and query API for Apple Health data collected from study participants.
`server/` holds the reference implementation; 43 tests, run with `make -C server test`.

## The shape of the problem

There is no Apple-side cloud API for Health data, and there is not going to be one — the
design is deliberate. HealthKit is device-local: no REST endpoint, no OAuth flow, no
server-side token. The only way health data leaves an iPhone is an app you wrote, running
on that phone, reading HealthKit and posting somewhere.

So the arrow points the other way from what "give me my Apple Watch data via an API"
usually implies. You do not pull from Apple. The phone pushes to an API you own, and
*that* is the API you query.

```
Apple Watch ──► iPhone Health store ──► your app (HealthKit read)
                                              │
                                              ▼  HTTPS, device token
                                     ┌──────────────────────┐
                                     │  nocturne-sync       │
                                     │  ingest · store      │
                                     └──────────┬───────────┘
                                                │  researcher token
                                                ▼
                                     R · Python · CSV export
```

The alternative is to buy the device-side layer: Terra, Junction (formerly Vital) and Rook
all sell an iOS SDK plus a cloud API, so you get a REST endpoint without writing the sync
code. You still ship an app to every participant — that part is unavoidable — and your
participants' health data now transits a third party, which is a consent-form and
data-processing-agreement question, not just a technical one. For a single-institution
study on one platform, the sync code is a few hundred lines and this service is it.

## Authentication

Bearer tokens, two scopes, and the split matters:

| Scope | Can | Cannot |
|---|---|---|
| `device` | post its own participant's data | read anything, including its own uploads |
| `researcher` | read a study | post data |

A participant's phone holds a write-only credential. If it is lost or the app is pulled
apart, nothing readable comes out of it. Tests assert this boundary directly, in both
directions.

Tokens are 256 bits of entropy stored as a SHA-256 digest. There is no password KDF because
there is nothing to guess — a slow hash defends low-entropy human secrets, not random
strings.

## Enrolment

Administration is CLI-only. No HTTP route creates studies, mints researcher tokens or
enrols participants; doing that needs shell access to the host.

```sh
nocturne-admin create-study OSU-HRV-2026 --name "Overnight HRV validation" --retention-days 1095
nocturne-admin add-participants --study OSU-HRV-2026 --count 40 --prefix P
# participant_code,enrolment_secret
# P001,xK3n_9dQm2Lv
# ...
nocturne-admin mint-researcher-token --label "PI" --study OSU-HRV-2026 --expires-days 365
```

Hand each participant their code and secret through whatever channel consent already uses.
They type both into the app once; the secret is single-use and the code locks after five
failed attempts. An unknown code and a wrong secret return byte-identical responses, so the
roster cannot be enumerated.

```
POST /v1/enrol
{"participant_code": "P001", "enrolment_secret": "xK3n_9dQm2Lv"}
→ {"device_token": "…", "participant_code": "P001", "schema_version": 1}
```

## Ingest

```
POST /v1/ingest          Authorization: Bearer <device token>
```

```json
{
  "schema_version": 1,
  "device": {"system_version": "iOS", "app_version": "0.1.0 (1)"},
  "series": [
    {
      "hk_uuid": "8B0E…",
      "start": "2026-03-01T23:30:00-05:00",
      "beats": [{"offset": 0.0, "precededByGap": false},
                {"offset": 1.021, "precededByGap": false}],
      "source_identifier": "com.apple.health",
      "device_name": "Apple Watch"
    }
  ],
  "sleep": [{"hk_uuid": "…", "stage": "deep",
             "start": "2026-03-02T01:10:00-05:00", "end": "2026-03-02T01:44:00-05:00"}],
  "context": [{"hk_uuid": "…", "type": "hrv_sdnn",
                "start": "…", "end": "…", "value": 48.2, "unit": "ms"}],
  "nights": [{"night_of": "2026-03-01", "config_hash": "e856a6e22faf7725",
               "hrvkit_version": "0.1.0", "analysed_at": "…",
               "summary": {…}, "config": {…}}],
  "deletions": [{"kind": "heartbeat_series", "hk_uuid": "…"}]
}
```

```json
→ {"accepted": {"series": 12, "sleep": 40, "context": 9, "nights": 1},
   "duplicate": {"series": 0, "sleep": 0, "context": 0, "nights": 0},
   "tombstoned": 0, "schema_version": 1}
```

Five things about this endpoint are load-bearing.

**There is no participant field.** The participant comes from the token. A compromised
device cannot attribute data to someone else, and there is nothing to get wrong in the
client.

**Ingest is idempotent**, keyed on the HealthKit sample UUID. Background sync on iOS
retries, duplicates and reorders; replaying an upload is a no-op and the response says how
much was already held. "Nothing uploaded" and "everything was already there" look identical
otherwise, so the counts are split.

**Timestamps must carry an offset.** A naive timestamp is rejected. This looks pedantic
until a night boundary lands on it: after the fact you cannot tell whether `02:00` meant
local or UTC, and there is no way to recover the answer.

**Beat offsets and gap flags go up verbatim.** `precededByGap` is HealthKit telling you the
interval ending at that beat is not a valid NN interval. Drop it and every downstream RMSSD
is wrong in a way nothing will flag. Offsets are validated strictly increasing.

**Derived summaries are keyed by configuration hash, and append-only.** Re-analysing a
night under a different artifact ceiling writes a second row rather than overwriting the
first, so a number can always be traced to the settings behind it. That is not
bookkeeping — the preprocessing choices in HRVKit move RMSSD by more than most readers
assume.

**Deletions are tombstones.** A sample removed from Health stops appearing in results but
stays on record. HealthKit reports a deletion exactly once, through the anchored query, so
a sync that ignores `HKDeletedObject` silently keeps serving withdrawn data.

### Resuming after a reinstall

```
GET /v1/sync/state?since=2026-01-01T00:00:00%2B00:00
```

Returns counts, the latest timestamps held, and the series UUIDs in the window. A device
that lost its HealthKit anchors uses this to bound the catch-up instead of re-uploading
everything it can still see.

## Query

All researcher scope. Every call is written to an audit log.

| Endpoint | Returns |
|---|---|
| `GET /v1/participants` | roster with enrolment state |
| `GET /v1/participants/{code}/series` | series metadata; `include_beats=true` for beats |
| `GET /v1/participants/{code}/sleep` | staged sleep intervals |
| `GET /v1/participants/{code}/context` | Apple SDNN, resting HR, respiratory rate |
| `GET /v1/participants/{code}/nights` | every analysis revision; `config_hash=` to pin one |
| `GET /v1/participants/{code}/beats.csv` | one row per beat, streamed |
| `GET /v1/export/nights.csv` | one row per participant-night, whole study |
| `GET /v1/metrics` | **flat one-row-per-night feed — the one to poll** |
| `GET /v1/metrics.csv` | the same rows as CSV |
| `GET /v1/audit` | who read what, when |

`/v1/metrics` exists because everything else here returns the full nested analysis, which
is right for reanalysis and wrong for a consumer that wants to join RMSSD onto its own
table. See [HUB_INTEGRATION.md](HUB_INTEGRATION.md).

Beats are not included in the JSON series listing unless asked for: a year of chest-strap
nights is tens of millions of beats and nobody means to pull that into a list by accident.
Use the CSV endpoint, which streams.

A researcher token scoped to one study cannot read another. Useful when a collaborator is
on trial A only.

### Query bounds

`from`, `to` and `since` take ISO 8601. Two conveniences, both deliberate:

- An unencoded `+` in an offset arrives as a space (`…T00:00:00 00:00`) and is repaired.
  Nothing else in ISO 8601 puts a space before an offset, so it is unambiguous — and
  refusing it just costs whoever writes the client an afternoon.
- An offset-less bound is read as UTC. Stored timestamps must be explicit because
  ambiguity there is permanent; a filter bound is different, and `?from=2026-03-01` is
  worth accepting.

### Getting the data into R

```r
library(httr); library(readr)
token <- Sys.getenv("NOCTURNE_TOKEN")
nights <- read_csv(content(GET("https://sync.example.edu/v1/export/nights.csv",
                               add_headers(Authorization = paste("Bearer", token))), "raw"))
beats  <- read_csv(content(GET("https://sync.example.edu/v1/participants/P001/beats.csv",
                               add_headers(Authorization = paste("Bearer", token))), "raw"))
```

`beats.csv` is the one that matters. It is the input an agreement analysis needs, and it
lets the whole HRV pipeline be re-run outside the app — in Kubios, in `hrv-analysis`, in
whatever you would defend to a reviewer.

## Interactive docs

`GET /docs` serves the generated OpenAPI UI, `GET /openapi.json` the spec. Point a client
generator at it rather than hand-writing request models.
