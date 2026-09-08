"""Ingest and query API for Apple Health data collected from study participants.

Design constraints this service is built around, in priority order:

1. **No participant PII.** The schema has no name, email, date of birth or free-text
   identity field. A participant is an opaque study-issued code. Re-identification lives
   in whatever the study already uses for its enrolment log, off this server. That keeps
   the linking key out of the system holding the health data.
2. **Idempotent ingest.** Background sync on iOS retries, duplicates and reorders.
   Everything is keyed on the HealthKit sample UUID, so replaying an upload is a no-op.
3. **Append-only for anything derived.** A night re-analysed under different preprocessing
   settings is stored as a new row keyed by the configuration hash, never an overwrite.
   You can always answer "which settings produced this number".
4. **Write-only devices.** A device token can post its own participant's data and read
   nothing. Reading across the study needs a separate researcher token, and every such
   read is logged.
"""

__version__ = "0.1.0"
SCHEMA_VERSION = 1
