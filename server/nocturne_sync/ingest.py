from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .auth import (
    Principal,
    assert_active,
    get_db,
    mint_token,
    require_device,
    secret_matches,
)
from .config import settings
from .db import (
    ContextSample,
    HeartbeatSeries,
    NightAnalysis,
    Participant,
    SleepInterval,
    Token,
    utcnow,
)
from .schemas import (
    SCHEMA_VERSION,
    WindowTime,
    EnrolRequest,
    EnrolResponse,
    IngestResult,
    SyncState,
    UploadEnvelope,
)

router = APIRouter(prefix="/v1", tags=["ingest"])


@router.post("/enrol", response_model=EnrolResponse)
def enrol(body: EnrolRequest, db: Session = Depends(get_db)) -> EnrolResponse:
    """Exchange a study-issued code and one-time secret for a device token.

    The secret is single-use and the attempt counter locks the code after a handful of
    failures, so a leaked participant code alone is not enough to start posting data.
    """
    participant = db.get(Participant, body.participant_code)
    # Deliberately the same message for an unknown code and a wrong secret: telling a
    # caller which codes exist would let them enumerate the roster.
    generic = HTTPException(status_code=401, detail="Enrolment failed")
    if participant is None:
        raise generic
    if participant.withdrawn_at is not None:
        raise HTTPException(status_code=410, detail="Participant has withdrawn")
    if participant.enrolment_secret_hash is None:
        raise HTTPException(status_code=409, detail="This code has already been used to enrol a device")
    if participant.enrolment_attempts >= settings.max_enrolment_attempts:
        raise HTTPException(status_code=429, detail="Too many enrolment attempts; contact the study team")

    if not secret_matches(body.enrolment_secret, participant.enrolment_secret_hash):
        participant.enrolment_attempts += 1
        db.commit()
        raise generic

    plaintext, digest = mint_token()
    db.add(
        Token(
            token_hash=digest,
            scope="device",
            study_id=participant.study_id,
            participant_code=participant.code,
            label=f"device:{participant.code}",
        )
    )
    participant.enrolment_secret_hash = None
    participant.enrolment_attempts = 0
    db.commit()
    return EnrolResponse(device_token=plaintext, participant_code=participant.code)


@router.post("/ingest", response_model=IngestResult)
async def ingest(
    request: Request,
    body: UploadEnvelope,
    principal: Principal = Depends(require_device),
    db: Session = Depends(get_db),
) -> IngestResult:
    code = principal.participant_code
    assert code is not None
    assert_active(db, code)

    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > settings.max_upload_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Upload exceeds {settings.max_upload_bytes} bytes; send fewer nights per batch",
        )

    accepted = {"series": 0, "sleep": 0, "context": 0, "nights": 0}
    duplicate = {"series": 0, "sleep": 0, "context": 0, "nights": 0}

    # --- Heartbeat series -----------------------------------------------------------
    if body.series:
        incoming = {s.hk_uuid: s for s in body.series}
        held = set(
            db.scalars(
                select(HeartbeatSeries.hk_uuid).where(
                    HeartbeatSeries.participant_code == code,
                    HeartbeatSeries.hk_uuid.in_(list(incoming)),
                )
            )
        )
        duplicate["series"] = len(held)
        for uuid, s in incoming.items():
            if uuid in held:
                continue
            db.add(
                HeartbeatSeries(
                    participant_code=code,
                    hk_uuid=uuid,
                    start=s.start,
                    end=s.end,
                    beat_count=len(s.beats),
                    source_identifier=s.source_identifier,
                    device_name=s.device_name,
                    beats=[b.model_dump() for b in s.beats],
                )
            )
            accepted["series"] += 1

    # --- Sleep ----------------------------------------------------------------------
    if body.sleep:
        incoming_sleep = {s.hk_uuid: s for s in body.sleep}
        held = set(
            db.scalars(
                select(SleepInterval.hk_uuid).where(
                    SleepInterval.participant_code == code,
                    SleepInterval.hk_uuid.in_(list(incoming_sleep)),
                )
            )
        )
        duplicate["sleep"] = len(held)
        for uuid, s in incoming_sleep.items():
            if uuid in held:
                continue
            db.add(
                SleepInterval(
                    participant_code=code,
                    hk_uuid=uuid,
                    stage=s.stage,
                    start=s.start,
                    end=s.end,
                    source_identifier=s.source_identifier,
                )
            )
            accepted["sleep"] += 1

    # --- Context quantities ---------------------------------------------------------
    if body.context:
        # A context sample is keyed by (uuid, type): HealthKit statistics can share a uuid
        # across types in some sources, so the type is part of the identity.
        incoming_ctx = {(c.hk_uuid, c.type): c for c in body.context}
        held_pairs = set(
            db.execute(
                select(ContextSample.hk_uuid, ContextSample.type).where(
                    ContextSample.participant_code == code,
                    ContextSample.hk_uuid.in_([u for u, _ in incoming_ctx]),
                )
            ).all()
        )
        duplicate["context"] = sum(1 for key in incoming_ctx if key in held_pairs)
        for (uuid, ctype), c in incoming_ctx.items():
            if (uuid, ctype) in held_pairs:
                continue
            db.add(
                ContextSample(
                    participant_code=code,
                    hk_uuid=uuid,
                    type=ctype,
                    start=c.start,
                    end=c.end,
                    value=c.value,
                    unit=c.unit,
                    source_identifier=c.source_identifier,
                )
            )
            accepted["context"] += 1

    # --- Derived night analyses -----------------------------------------------------
    if body.nights:
        incoming_nights = {(n.night_of, n.config_hash): n for n in body.nights}
        held_nights = set(
            db.execute(
                select(NightAnalysis.night_of, NightAnalysis.config_hash).where(
                    NightAnalysis.participant_code == code,
                    NightAnalysis.night_of.in_([d for d, _ in incoming_nights]),
                )
            ).all()
        )
        duplicate["nights"] = sum(1 for key in incoming_nights if key in held_nights)
        for key, n in incoming_nights.items():
            if key in held_nights:
                continue
            db.add(
                NightAnalysis(
                    participant_code=code,
                    night_of=n.night_of,
                    config_hash=n.config_hash,
                    hrvkit_version=n.hrvkit_version,
                    analysed_at=n.analysed_at,
                    summary=n.summary,
                    config=n.config,
                )
            )
            accepted["nights"] += 1

    # --- Tombstones -----------------------------------------------------------------
    # A sample deleted in Health is marked deleted here, never removed. Deleting the row
    # would make the deletion itself invisible, and "this beat series was withdrawn on
    # date X" is information a reviewer can reasonably ask for.
    tombstoned = 0
    now = utcnow()
    table_for = {
        "heartbeat_series": HeartbeatSeries,
        "sleep_interval": SleepInterval,
        "context_sample": ContextSample,
    }
    for deletion in body.deletions:
        model = table_for[deletion.kind]
        rows = db.scalars(
            select(model).where(
                model.participant_code == code,
                model.hk_uuid == deletion.hk_uuid,
                model.deleted_at.is_(None),
            )
        ).all()
        for row in rows:
            row.deleted_at = now
            tombstoned += 1

    db.commit()
    return IngestResult(accepted=accepted, duplicate=duplicate, tombstoned=tombstoned)


@router.get("/sync/state", response_model=SyncState)
def sync_state(
    since: WindowTime | None = Query(
        default=None,
        description=(
            "Bound the returned uuid list, ISO 8601. An offset-less value is read as UTC. "
            "Omit it to get counts only."
        ),
    ),
    principal: Principal = Depends(require_device),
    db: Session = Depends(get_db),
) -> SyncState:
    """What the server already holds for this device's participant.

    A device that has been reinstalled has lost its HealthKit anchors. Without this it
    would re-upload every beat it can still see; with it, the client can skip what the
    server already has. `since` bounds the uuid list so the response stays small.
    """
    code = principal.participant_code
    assert code is not None

    def latest(model, column):
        return db.scalar(select(func.max(column)).where(model.participant_code == code))

    def count(model):
        return db.scalar(
            select(func.count()).where(model.participant_code == code, model.deleted_at.is_(None))
        ) or 0

    uuids: list[str] = []
    if since is not None:
        uuids = list(
            db.scalars(
                select(HeartbeatSeries.hk_uuid)
                .where(
                    HeartbeatSeries.participant_code == code,
                    HeartbeatSeries.start >= since,
                )
                .limit(20_000)
            )
        )

    return SyncState(
        participant_code=code,
        series_count=count(HeartbeatSeries),
        latest_series_start=latest(HeartbeatSeries, HeartbeatSeries.start),
        sleep_count=count(SleepInterval),
        latest_sleep_start=latest(SleepInterval, SleepInterval.start),
        night_count=db.scalar(
            select(func.count()).where(NightAnalysis.participant_code == code)
        ) or 0,
        latest_night_of=latest(NightAnalysis, NightAnalysis.night_of),
        known_series_uuids_since=since,
        known_series_uuids=uuids,
    )
