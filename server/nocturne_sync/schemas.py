"""Wire format, version 1.

These models are the contract between the iOS uploader and this service. The Swift side
mirrors them in `Apps/Shared/Sync/SyncWireFormat.swift`; if you change one, change both and
bump `SCHEMA_VERSION`.

Times are ISO 8601 with an explicit offset, always. A naive timestamp in sleep data is a
silent, unrecoverable error — you cannot tell afterwards whether 02:00 was local or UTC,
and a night boundary lands right on top of the ambiguity.
"""

from __future__ import annotations

import datetime as dt
import re
from typing import Annotated, Any, Literal, Optional

from pydantic import AfterValidator, BaseModel, BeforeValidator, Field, field_validator

SCHEMA_VERSION = 1

SleepStage = Literal["inBed", "awake", "core", "deep", "rem", "unspecified"]
ContextType = Literal["hrv_sdnn", "heart_rate", "resting_heart_rate", "respiratory_rate"]


def _require_aware(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("timestamps must carry an explicit UTC offset")
    return value


class BeatIn(BaseModel):
    offset: float = Field(ge=0, description="Seconds since the start of the series.")
    precededByGap: bool = False


class HeartbeatSeriesIn(BaseModel):
    hk_uuid: str = Field(min_length=1, max_length=64)
    start: dt.datetime
    beats: list[BeatIn] = Field(min_length=2, max_length=200_000)
    source_identifier: Optional[str] = Field(default=None, max_length=256)
    device_name: Optional[str] = Field(default=None, max_length=256)

    _aware_start = field_validator("start")(_require_aware)

    @field_validator("beats")
    @classmethod
    def monotonic(cls, beats: list[BeatIn]) -> list[BeatIn]:
        offsets = [b.offset for b in beats]
        if any(b <= a for a, b in zip(offsets, offsets[1:])):
            raise ValueError("beat offsets must be strictly increasing")
        return beats

    @property
    def end(self) -> dt.datetime:
        return self.start + dt.timedelta(seconds=self.beats[-1].offset)


class SleepIntervalIn(BaseModel):
    hk_uuid: str = Field(min_length=1, max_length=64)
    stage: SleepStage
    start: dt.datetime
    end: dt.datetime
    source_identifier: Optional[str] = Field(default=None, max_length=256)

    _aware_start = field_validator("start")(_require_aware)
    _aware_end = field_validator("end")(_require_aware)

    @field_validator("end")
    @classmethod
    def ordered(cls, end: dt.datetime, info: Any) -> dt.datetime:
        start = info.data.get("start")
        if start is not None and end < start:
            raise ValueError("end must not precede start")
        return end


class ContextSampleIn(BaseModel):
    hk_uuid: str = Field(min_length=1, max_length=64)
    type: ContextType
    start: dt.datetime
    end: dt.datetime
    value: float
    unit: str = Field(min_length=1, max_length=32)
    source_identifier: Optional[str] = Field(default=None, max_length=256)

    _aware_start = field_validator("start")(_require_aware)
    _aware_end = field_validator("end")(_require_aware)


class NightAnalysisIn(BaseModel):
    night_of: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    config_hash: str = Field(min_length=8, max_length=64)
    hrvkit_version: str = Field(max_length=32)
    analysed_at: dt.datetime
    summary: dict[str, Any]
    config: dict[str, Any]

    _aware_analysed = field_validator("analysed_at")(_require_aware)


class DeletionIn(BaseModel):
    """A HealthKit HKDeletedObject. Recorded as a tombstone rather than a hard delete."""

    kind: Literal["heartbeat_series", "sleep_interval", "context_sample"]
    hk_uuid: str = Field(min_length=1, max_length=64)


class DeviceInfo(BaseModel):
    model: Optional[str] = Field(default=None, max_length=64)
    system_version: Optional[str] = Field(default=None, max_length=64)
    app_version: Optional[str] = Field(default=None, max_length=64)


class UploadEnvelope(BaseModel):
    schema_version: int
    device: DeviceInfo = DeviceInfo()
    series: list[HeartbeatSeriesIn] = []
    sleep: list[SleepIntervalIn] = []
    context: list[ContextSampleIn] = []
    nights: list[NightAnalysisIn] = []
    deletions: list[DeletionIn] = []

    @field_validator("schema_version")
    @classmethod
    def supported(cls, v: int) -> int:
        if v != SCHEMA_VERSION:
            raise ValueError(f"unsupported schema_version {v}; this server speaks {SCHEMA_VERSION}")
        return v


class IngestResult(BaseModel):
    """Counts are per-kind: how many rows were new versus already held.

    The client uses `duplicate` to confirm a retry landed on data the server already has,
    which is the normal and expected case after a dropped connection.
    """

    accepted: dict[str, int]
    duplicate: dict[str, int]
    tombstoned: int
    schema_version: int = SCHEMA_VERSION


class EnrolRequest(BaseModel):
    participant_code: str = Field(min_length=1, max_length=64)
    enrolment_secret: str = Field(min_length=8, max_length=128)
    device: DeviceInfo = DeviceInfo()


class EnrolResponse(BaseModel):
    device_token: str
    participant_code: str
    schema_version: int = SCHEMA_VERSION


class SyncState(BaseModel):
    """What the server already holds, so a device that lost its HealthKit anchors can
    resume without re-uploading a year of beats."""

    participant_code: str
    series_count: int
    latest_series_start: Optional[dt.datetime]
    sleep_count: int
    latest_sleep_start: Optional[dt.datetime]
    night_count: int
    latest_night_of: Optional[str]
    known_series_uuids_since: Optional[dt.datetime] = None
    known_series_uuids: list[str] = []


# --- Query-window timestamps --------------------------------------------------------

_UNENCODED_OFFSET = re.compile(r" (\d{2}:?\d{2})$")


def _repair_query_timestamp(value: Any) -> Any:
    """Repair the two ways an ISO 8601 instant reliably gets mangled in a query string.

    A "+" that was not percent-encoded arrives as a space, so `2026-03-01T00:00:00+00:00`
    becomes `2026-03-01T00:00:00 00:00`. Nothing else in ISO 8601 puts a space immediately
    before a UTC offset, so repairing it is unambiguous — and refusing it instead just
    costs whoever is writing the client an hour. A trailing "Z" is also normalised, since
    older parsers emit it and some accept only the numeric form.
    """
    if not isinstance(value, str):
        return value
    text = value.strip()
    text = _UNENCODED_OFFSET.sub(r"+\1", text)
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    return text


def _assume_utc(value: dt.datetime) -> dt.datetime:
    """Interpret an offset-less query bound as UTC.

    Stored timestamps must carry an offset — ambiguity there is permanent. A filter bound
    is different: the worst case is a few hours of visible boundary slop, so accepting
    `?from=2026-03-01` is worth more than the strictness. The assumption is stated in the
    parameter description so it shows up in the generated API docs.
    """
    return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)


WindowTime = Annotated[
    dt.datetime, BeforeValidator(_repair_query_timestamp), AfterValidator(_assume_utc)
]
