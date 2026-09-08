"""Read API. Researcher scope only, every call logged."""

from __future__ import annotations

import csv
import datetime as dt
import io
import math
from typing import Any, Iterable, Optional

from fastapi import APIRouter, Depends, Query
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import Principal, epoch, get_db, log_access, require_researcher, researcher_may_read
from .db import ContextSample, HeartbeatSeries, NightAnalysis, Participant, SleepInterval
from .schemas import WindowTime

router = APIRouter(prefix="/v1", tags=["query"])

MAX_PAGE = 1000


def _window(stmt, column, frm: Optional[dt.datetime], to: Optional[dt.datetime]):
    if frm is not None:
        stmt = stmt.where(column >= frm)
    if to is not None:
        stmt = stmt.where(column < to)
    return stmt


@router.get("/participants")
def list_participants(
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    stmt = select(Participant)
    if principal.study_id is not None:
        stmt = stmt.where(Participant.study_id == principal.study_id)
    rows = db.scalars(stmt.order_by(Participant.code)).all()
    log_access(db, principal, "GET /v1/participants", None, len(rows))
    return [
        {
            "participant_code": r.code,
            "study_id": r.study_id,
            "enrolled_at": epoch(r.enrolled_at),
            "withdrawn_at": epoch(r.withdrawn_at),
            "device_enrolled": r.enrolment_secret_hash is None,
        }
        for r in rows
    ]


@router.get("/participants/{code}/series")
def list_series(
    code: str,
    frm: Optional[WindowTime] = Query(
        default=None,
        alias="from",
        description="Inclusive lower bound, ISO 8601. An offset-less value is read as UTC.",
    ),
    to: Optional[WindowTime] = Query(
        default=None, description="Exclusive upper bound, ISO 8601. Offset-less is read as UTC."
    ),
    include_beats: bool = False,
    include_deleted: bool = False,
    limit: int = Query(default=200, le=MAX_PAGE, ge=1),
    offset: int = Query(default=0, ge=0),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    """Heartbeat series metadata, with the beats themselves behind a flag.

    `include_beats=false` by default because a year of chest-strap nights is tens of
    millions of beats and nobody means to pull that into a JSON response by accident.
    Use the CSV endpoint for bulk beat extraction.
    """
    researcher_may_read(db, principal, code)
    stmt = select(HeartbeatSeries).where(HeartbeatSeries.participant_code == code)
    if not include_deleted:
        stmt = stmt.where(HeartbeatSeries.deleted_at.is_(None))
    stmt = _window(stmt, HeartbeatSeries.start, frm, to)
    rows = db.scalars(stmt.order_by(HeartbeatSeries.start).limit(limit).offset(offset)).all()
    log_access(db, principal, "GET /v1/participants/{code}/series", code, len(rows))

    out = []
    for r in rows:
        item = {
            "hk_uuid": r.hk_uuid,
            "start": epoch(r.start),
            "end": epoch(r.end),
            "beat_count": r.beat_count,
            "source_identifier": r.source_identifier,
            "device_name": r.device_name,
            "received_at": epoch(r.received_at),
            "deleted_at": epoch(r.deleted_at),
        }
        if include_beats:
            item["beats"] = r.beats
        out.append(item)
    return out


@router.get("/participants/{code}/sleep")
def list_sleep(
    code: str,
    frm: Optional[WindowTime] = Query(
        default=None,
        alias="from",
        description="Inclusive lower bound, ISO 8601. An offset-less value is read as UTC.",
    ),
    to: Optional[WindowTime] = Query(
        default=None, description="Exclusive upper bound, ISO 8601. Offset-less is read as UTC."
    ),
    limit: int = Query(default=500, le=MAX_PAGE, ge=1),
    offset: int = Query(default=0, ge=0),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    researcher_may_read(db, principal, code)
    stmt = select(SleepInterval).where(
        SleepInterval.participant_code == code, SleepInterval.deleted_at.is_(None)
    )
    stmt = _window(stmt, SleepInterval.start, frm, to)
    rows = db.scalars(stmt.order_by(SleepInterval.start).limit(limit).offset(offset)).all()
    log_access(db, principal, "GET /v1/participants/{code}/sleep", code, len(rows))
    return [
        {
            "hk_uuid": r.hk_uuid,
            "stage": r.stage,
            "start": epoch(r.start),
            "end": epoch(r.end),
            "source_identifier": r.source_identifier,
        }
        for r in rows
    ]


@router.get("/participants/{code}/context")
def list_context(
    code: str,
    type: Optional[str] = None,
    frm: Optional[WindowTime] = Query(
        default=None,
        alias="from",
        description="Inclusive lower bound, ISO 8601. An offset-less value is read as UTC.",
    ),
    to: Optional[WindowTime] = Query(
        default=None, description="Exclusive upper bound, ISO 8601. Offset-less is read as UTC."
    ),
    limit: int = Query(default=500, le=MAX_PAGE, ge=1),
    offset: int = Query(default=0, ge=0),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    researcher_may_read(db, principal, code)
    stmt = select(ContextSample).where(
        ContextSample.participant_code == code, ContextSample.deleted_at.is_(None)
    )
    if type is not None:
        stmt = stmt.where(ContextSample.type == type)
    stmt = _window(stmt, ContextSample.start, frm, to)
    rows = db.scalars(stmt.order_by(ContextSample.start).limit(limit).offset(offset)).all()
    log_access(db, principal, "GET /v1/participants/{code}/context", code, len(rows))
    return [
        {
            "hk_uuid": r.hk_uuid,
            "type": r.type,
            "start": epoch(r.start),
            "end": epoch(r.end),
            "value": r.value,
            "unit": r.unit,
        }
        for r in rows
    ]


@router.get("/participants/{code}/nights")
def list_nights(
    code: str,
    config_hash: Optional[str] = None,
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    """Derived night summaries.

    Without `config_hash` this returns every analysis revision, which is deliberate: if a
    night was analysed twice under different settings you should see both rather than
    silently get whichever arrived last. Pass `config_hash` to pin one configuration.
    """
    researcher_may_read(db, principal, code)
    stmt = select(NightAnalysis).where(NightAnalysis.participant_code == code)
    if config_hash is not None:
        stmt = stmt.where(NightAnalysis.config_hash == config_hash)
    rows = db.scalars(stmt.order_by(NightAnalysis.night_of, NightAnalysis.received_at)).all()
    log_access(db, principal, "GET /v1/participants/{code}/nights", code, len(rows))
    return [
        {
            "night_of": r.night_of,
            "config_hash": r.config_hash,
            "hrvkit_version": r.hrvkit_version,
            "analysed_at": epoch(r.analysed_at),
            "summary": r.summary,
            "config": r.config,
        }
        for r in rows
    ]


# --- Bulk extraction ----------------------------------------------------------------


def _stream_csv(
    header: list[str], rows: Iterable[list[Any]], filename: str
) -> StreamingResponse:
    """Stream RFC 4180 CSV (CRLF line endings, which R and pandas both read directly).

    Streamed rather than assembled because a year of chest-strap beats is tens of millions
    of rows and buffering it would take the process down.
    """

    def generate():
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(header)
        yield buffer.getvalue()
        buffer.seek(0), buffer.truncate(0)
        for row in rows:
            writer.writerow(row)
            yield buffer.getvalue()
            buffer.seek(0), buffer.truncate(0)

    return StreamingResponse(
        generate(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/participants/{code}/beats.csv")
def beats_csv(
    code: str,
    frm: Optional[WindowTime] = Query(
        default=None,
        alias="from",
        description="Inclusive lower bound, ISO 8601. An offset-less value is read as UTC.",
    ),
    to: Optional[WindowTime] = Query(
        default=None, description="Exclusive upper bound, ISO 8601. Offset-less is read as UTC."
    ),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
):
    """Every beat in the window, one row each, streamed.

    This is the endpoint that makes the whole service worth having: it is the input an
    agreement analysis needs, and it comes out in a shape R or Python reads directly.
    """
    researcher_may_read(db, principal, code)
    stmt = select(HeartbeatSeries).where(
        HeartbeatSeries.participant_code == code, HeartbeatSeries.deleted_at.is_(None)
    )
    stmt = _window(stmt, HeartbeatSeries.start, frm, to)
    series = db.scalars(stmt.order_by(HeartbeatSeries.start)).all()
    total = sum(s.beat_count for s in series)
    log_access(db, principal, "GET /v1/participants/{code}/beats.csv", code, total)

    def rows():
        for s in series:
            start = epoch(s.start)
            for index, beat in enumerate(s.beats):
                offset = float(beat.get("offset", 0.0))
                yield [
                    code,
                    s.hk_uuid,
                    start.isoformat(),
                    index,
                    f"{offset:.6f}",
                    (start + dt.timedelta(seconds=offset)).isoformat(),
                    1 if beat.get("precededByGap") else 0,
                    s.source_identifier or "",
                    s.device_name or "",
                ]

    return _stream_csv(
        [
            "participant_code",
            "series_uuid",
            "series_start_iso",
            "beat_index",
            "t_since_series_start_s",
            "absolute_time_iso",
            "preceded_by_gap",
            "source",
            "device",
        ],
        rows(),
        filename=f"beats-{code}.csv",
    )


@router.get("/export/nights.csv")
def nights_csv(
    config_hash: Optional[str] = None,
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
):
    """One row per participant-night across the whole study — the analysis-ready table."""
    stmt = select(NightAnalysis, Participant).join(
        Participant, Participant.code == NightAnalysis.participant_code
    )
    if principal.study_id is not None:
        stmt = stmt.where(Participant.study_id == principal.study_id)
    if config_hash is not None:
        stmt = stmt.where(NightAnalysis.config_hash == config_hash)
    rows = db.execute(
        stmt.order_by(NightAnalysis.participant_code, NightAnalysis.night_of)
    ).all()
    log_access(db, principal, "GET /v1/export/nights.csv", None, len(rows))

    fields = [
        "quality",
        "usedWindowCount",
        "coverage",
        "artifactFraction",
        "rmssd",
        "lnRMSSD",
        "sdnn",
        "meanHR",
        "minHR",
        "pnn50",
        "sd1",
        "sd2",
    ]
    alternate_keys = sorted(
        {k for night, _ in rows for k in (night.summary.get("alternates") or {})}
    )
    header = (
        ["participant_code", "study_id", "night_of", "config_hash", "hrvkit_version", "analysed_at"]
        + fields
        + [f"alt_{k.replace('.', '_')}" for k in alternate_keys]
    )

    def generate():
        for night, participant in rows:
            summary = night.summary or {}
            alternates = summary.get("alternates") or {}
            yield (
                [
                    night.participant_code,
                    participant.study_id,
                    night.night_of,
                    night.config_hash,
                    night.hrvkit_version,
                    epoch(night.analysed_at).isoformat(),
                ]
                + [summary.get(f, "") for f in fields]
                + [alternates.get(k, "") for k in alternate_keys]
            )

    return _stream_csv(header, generate(), filename="nights.csv")


@router.get("/audit")
def audit(
    limit: int = Query(default=200, le=MAX_PAGE, ge=1),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    """The read log. Exposed so a PI can inspect access without database credentials."""
    from .db import AccessLog

    rows = db.scalars(select(AccessLog).order_by(AccessLog.at.desc()).limit(limit)).all()
    return [
        {
            "at": epoch(r.at),
            "token_label": r.token_label,
            "scope": r.scope,
            "endpoint": r.endpoint,
            "participant_code": r.participant_code,
            "row_count": r.row_count,
        }
        for r in rows
    ]


# --- Flat metric feed ----------------------------------------------------------------


@router.get("/metrics")
def metrics(
    participant: Optional[str] = Query(default=None, description="Participant code; omit for the whole study."),
    frm: Optional[str] = Query(
        default=None, alias="from", pattern=r"^\d{4}-\d{2}-\d{2}$",
        description="Earliest night_of, inclusive (yyyy-MM-dd).",
    ),
    to: Optional[str] = Query(
        default=None, pattern=r"^\d{4}-\d{2}-\d{2}$",
        description="Latest night_of, inclusive (yyyy-MM-dd).",
    ),
    config_hash: Optional[str] = Query(
        default=None, description="Pin one preprocessing configuration."
    ),
    all_revisions: bool = Query(
        default=False,
        description=(
            "Return every analysis revision of a night instead of only the most recently "
            "analysed one."
        ),
    ),
    limit: int = Query(default=500, le=5000, ge=1),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    """One flat row per participant-night. This is the feed to poll.

    Everything else in this API returns the full nested analysis, which is right for
    reanalysis and wrong for a consumer that wants to join RMSSD onto its own table. Here
    the fields are scalars, the key is `(participant_code, night_of)`, and the units are in
    the field names.

    Two behaviours worth knowing about, both there to keep a consumer's history stable:

    **Revisions.** A night re-analysed under different preprocessing is stored as a
    separate row, so a night can have several. By default this returns only the most
    recently analysed one and reports `revision_count` so a consumer can see when others
    exist; `all_revisions=true` returns them all. It never silently averages them.

    **`config_hash` is in every row.** If it changes between two polls, the number changed
    because the preprocessing changed, not because the participant did. A consumer that
    stores the hash alongside the value can tell those two cases apart, which is otherwise
    impossible after the fact.
    """
    stmt = select(NightAnalysis, Participant).join(
        Participant, Participant.code == NightAnalysis.participant_code
    )
    if principal.study_id is not None:
        stmt = stmt.where(Participant.study_id == principal.study_id)
    if participant is not None:
        researcher_may_read(db, principal, participant)
        stmt = stmt.where(NightAnalysis.participant_code == participant)
    if frm is not None:
        stmt = stmt.where(NightAnalysis.night_of >= frm)
    if to is not None:
        stmt = stmt.where(NightAnalysis.night_of <= to)
    if config_hash is not None:
        stmt = stmt.where(NightAnalysis.config_hash == config_hash)

    rows = db.execute(
        stmt.order_by(
            NightAnalysis.participant_code,
            NightAnalysis.night_of,
            NightAnalysis.analysed_at,
        )
    ).all()

    # Group by (participant, night) so revisions can be counted and, by default, collapsed
    # to the latest.
    grouped: dict[tuple[str, str], list[Any]] = {}
    for night, _ in rows:
        grouped.setdefault((night.participant_code, night.night_of), []).append(night)

    def row_for(night: Any, revisions: int) -> dict[str, Any]:
        summary = night.summary or {}

        def value(key: str) -> Optional[float]:
            """Scalar or null. Never a non-finite number, and never a string.

            "No number" is a real state here: an empty night, or a metric the window count
            cannot support. The analysis represents it as NaN, and the Swift client encodes
            non-finite doubles as the strings "NaN" / "Infinity" / "-Infinity" because JSON
            has no literal for them. Both forms have to collapse to null — a consumer that
            received the string "NaN" where it expected a float would either crash or, much
            worse, coerce it to something.
            """
            raw = summary.get(key)
            if isinstance(raw, str):
                return None
            if isinstance(raw, bool) or not isinstance(raw, (int, float)):
                return None
            value = float(raw)
            return None if math.isnan(value) or math.isinf(value) else value

        return {
            "participant_code": night.participant_code,
            "night_of": night.night_of,
            "rmssd_ms": value("rmssd"),
            "ln_rmssd": value("lnRMSSD"),
            "sdnn_ms": value("sdnn"),
            "mean_hr_bpm": value("meanHR"),
            "min_hr_bpm": value("minHR"),
            "pnn50_pct": value("pnn50"),
            "sd1_ms": value("sd1"),
            "sd2_ms": value("sd2"),
            "aggregation": "median_of_windows",
            "window_count": summary.get("usedWindowCount"),
            "coverage_s": value("coverage"),
            "artifact_fraction": value("artifactFraction"),
            "quality": summary.get("quality"),
            "sources": night.sources or [],
            "config_hash": night.config_hash,
            "hrvkit_version": night.hrvkit_version,
            "analysed_at": epoch(night.analysed_at),
            "received_at": epoch(night.received_at),
            "revision_count": revisions,
        }

    out: list[dict[str, Any]] = []
    for revisions in grouped.values():
        chosen = revisions if all_revisions else [revisions[-1]]
        for night in chosen:
            out.append(row_for(night, len(revisions)))
    out.sort(key=lambda r: (r["participant_code"], r["night_of"], r["analysed_at"]))

    log_access(db, principal, "GET /v1/metrics", participant, len(out))
    return out[:limit]


@router.get("/metrics.csv")
def metrics_csv(
    participant: Optional[str] = Query(default=None),
    frm: Optional[str] = Query(default=None, alias="from", pattern=r"^\d{4}-\d{2}-\d{2}$"),
    to: Optional[str] = Query(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
    config_hash: Optional[str] = Query(default=None),
    principal: Principal = Depends(require_researcher),
    db: Session = Depends(get_db),
):
    """The same feed as CSV, for a consumer that would rather read a file than JSON."""
    rows = metrics(
        participant=participant, frm=frm, to=to, config_hash=config_hash,
        all_revisions=False, limit=5000, principal=principal, db=db,
    )
    header = [
        "participant_code", "night_of", "rmssd_ms", "ln_rmssd", "sdnn_ms", "mean_hr_bpm",
        "min_hr_bpm", "pnn50_pct", "sd1_ms", "sd2_ms", "aggregation", "window_count",
        "coverage_s", "artifact_fraction", "quality", "sources", "config_hash",
        "hrvkit_version", "analysed_at", "revision_count",
    ]

    def generate():
        for row in rows:
            yield [
                "|".join(row[key]) if key == "sources" else
                (row[key].isoformat() if key == "analysed_at" and row[key] else row[key])
                for key in header
            ]

    return _stream_csv(header, generate(), filename="rmssd.csv")
