# Running a study with this

Practical notes on the parts that are not code. None of this is legal or IRB advice — your
IRB and your institution's data governance office decide, and they will have specific
requirements this document cannot anticipate. What follows is the set of questions they will
ask, and what the software already does about each.

## Getting the app onto participants' phones

You cannot sideload onto someone else's iPhone. The realistic options, in order of how well
they fit a study:

| Path | Cap | Review | Fit |
|---|---|---|---|
| **TestFlight, external** | 10,000 testers | Beta App Review on the first build of each version, 24–48 h | The default. Participants install the TestFlight app and accept a link. |
| TestFlight, internal | 100 | none, instant builds | Your own team's devices only — testers must be App Store Connect users. |
| Ad Hoc | 100 devices/year | none | Needs each device's UDID up front. Painful past a handful of people. |
| Apple Business Manager custom app | unlimited | full App Review | Only if your institution already runs ABM and you want a managed deployment. |
| Public App Store | unlimited | full App Review, Guideline 5.1.3 | Overkill for a study, and invites support load from strangers. |

TestFlight builds expire after 90 days, so a 12-month protocol needs a new build roughly
quarterly. Put that in the study calendar — a lapsed build silently stops data collection,
and you will find out from a gap in the data.

## What Apple's rules constrain

Guideline 5.1.3 applies to anything reading HealthKit, TestFlight included:

- Health data may not be used or disclosed for advertising, marketing or use-based data
  mining. Health research is an allowed purpose, and only with permission.
- **Personal health information may not be stored in iCloud.** This is why the app's local
  store is plain SwiftData with no CloudKit container, and why you should not "helpfully"
  turn one on. Your own server is fine; Apple's sync is not.
- Apps may not write false or inaccurate data into HealthKit. The app only writes
  chest-strap beats it actually received.

## Where identity lives

The server schema has no name, email, date of birth or free-text identity field. A
participant is an opaque code. The mapping from code to person stays in your existing
enrolment log, off this server.

That is worth doing on day one because it is nearly free now and expensive later. It shrinks
what a breach of the health-data store actually exposes, it makes "can we share the dataset"
a much shorter conversation, and it means a collaborator can be given a read token without
being given a roster.

It does not make the data anonymous, and do not tell an IRB that it does. Longitudinal
overnight physiology at beat-level resolution is highly distinctive; coded is the honest
word, not anonymised.

## Consent, and what the app actually does

Points participants tend to ask about, and the true answers:

- **What is collected.** Beat-to-beat intervals, sleep stages, and heart rate and
  respiratory rate summaries — only within the windows the app queries. Not location, not
  workouts, not steps, not anything else in Health.
- **Direction of flow.** One-way. The app can post and cannot read the server, including
  its own past uploads. So a participant's phone cannot show them other participants' data
  because it cannot fetch any data at all.
- **Withdrawal.** `nocturne-admin withdraw P001` revokes the device token and blocks
  further ingest immediately. Deletion is a separate explicit flag, because *"you may
  withdraw"* and *"you may withdraw and have your data deleted"* are different promises and
  only your consent form knows which one you made. Decide which, before enrolment, and set
  the flag to match.
- **Revocation is not deletion.** A participant who removes Health permissions in iOS
  Settings stops new uploads but does not remove what is already collected. If your consent
  form implies otherwise, say so explicitly, or purge on withdrawal.

## Retention

Set `retention_days` per study and run `nocturne-admin prune` on a schedule. It is a dry
run unless `--apply`, and it prints what it would remove. A retention policy that only
exists in the protocol document is not a retention policy.

## Operating the server

- **HTTPS is mandatory** and enforced in code; the service refuses plaintext requests
  unless `NOCTURNE_REQUIRE_HTTPS=0`, which is for local development only.
- **Encryption at rest** is the host's job, not the application's. Use an encrypted volume
  or a managed Postgres with encryption enabled. SQLite is the default for development;
  point `NOCTURNE_DATABASE_URL` at Postgres for anything real.
- **Back it up, and test restoring it.** This is the only copy of data you cannot
  re-collect — a participant's Health store keeps a rolling window, so a night lost here is
  gone.
- **Host it where your institution allows health data to live.** For a university that
  usually means institutional infrastructure rather than a personal cloud account, and the
  answer often differs for identifiable versus coded data. Ask before you provision.
- **Rotate researcher tokens** with `--expires-days` and revoke on staff changes. The audit
  log (`GET /v1/audit`) shows which token read what.

## What is still missing for a real deployment

Being explicit about the gaps, because they are the kind that get discovered late:

- **No in-app consent flow.** The app assumes consent happened before enrolment. If your
  protocol needs consent captured in-app, with a version and a timestamp, that is work.
- **No compliance monitoring.** Nothing tells you a participant's watch stopped syncing
  three weeks ago. For a longitudinal study that is the single most valuable thing to add
  next: a per-participant last-upload view, and an alert when a device goes quiet.
- **No rate limiting beyond enrolment attempts.** Put the service behind a reverse proxy
  that does it.
- **HIPAA is not addressed.** A university research study is usually not a covered entity's
  treatment, payment or operations, so HIPAA often does not apply — but if your study
  touches a clinical partner, a covered entity, or protected health information from one, it
  can, and the requirements are substantially more than this. Confirm with your compliance
  office rather than inferring.
- **GDPR is not addressed** and applies if you enrol anyone in the EU or UK.

## Sources

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — 5.1.3 covers health, fitness and research data
- [TestFlight beta testing](https://developer.apple.com/testflight/) — tester caps, Beta App Review, 90-day build expiry
- [HealthKit documentation](https://developer.apple.com/documentation/healthkit) — authorization, anchored queries, background delivery
