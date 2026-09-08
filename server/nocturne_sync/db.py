from __future__ import annotations

import datetime as dt
from typing import Any, Optional

from sqlalchemy import (
    JSON,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    create_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker

from .config import settings


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


class Base(DeclarativeBase):
    type_annotation_map = {dict[str, Any]: JSON, list[Any]: JSON}


class Study(Base):
    __tablename__ = "study"
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(256))
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    # Days after which rows are eligible for deletion, per the study's retention plan.
    # Enforced by the `nocturne-admin prune` command, not silently at read time.
    retention_days: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)


class Participant(Base):
    """A study-issued opaque code. Deliberately holds no identifying information."""

    __tablename__ = "participant"
    code: Mapped[str] = mapped_column(String(64), primary_key=True)
    study_id: Mapped[str] = mapped_column(ForeignKey("study.id"), index=True)
    enrolled_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    # Set when a participant withdraws. Ingest is refused from that point; existing rows
    # are kept or purged according to what the consent form promised.
    withdrawn_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    # Hash of the one-time enrolment secret. Cleared once a device has enrolled.
    enrolment_secret_hash: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    enrolment_attempts: Mapped[int] = mapped_column(Integer, default=0)


class Token(Base):
    """Bearer credential. Only the hash is stored; the plaintext exists once, at mint time."""

    __tablename__ = "token"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    # "device" (write its own participant only) or "researcher" (read a whole study).
    scope: Mapped[str] = mapped_column(String(16))
    study_id: Mapped[Optional[str]] = mapped_column(ForeignKey("study.id"), nullable=True)
    participant_code: Mapped[Optional[str]] = mapped_column(
        ForeignKey("participant.code"), nullable=True, index=True
    )
    label: Mapped[str] = mapped_column(String(128), default="")
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    expires_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    last_used_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)


class HeartbeatSeries(Base):
    """One HKHeartbeatSeriesSample, beats and gap flags preserved verbatim."""

    __tablename__ = "heartbeat_series"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    participant_code: Mapped[str] = mapped_column(ForeignKey("participant.code"), index=True)
    hk_uuid: Mapped[str] = mapped_column(String(64))
    start: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)
    end: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    beat_count: Mapped[int] = mapped_column(Integer)
    source_identifier: Mapped[Optional[str]] = mapped_column(String(256), nullable=True)
    device_name: Mapped[Optional[str]] = mapped_column(String(256), nullable=True)
    # [{"offset": 0.0, "precededByGap": false}, ...] exactly as HealthKit reported it.
    beats: Mapped[list[Any]] = mapped_column(JSON)
    received_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    deleted_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("participant_code", "hk_uuid", name="uq_series_participant_uuid"),
        Index("ix_series_participant_start", "participant_code", "start"),
    )


class SleepInterval(Base):
    __tablename__ = "sleep_interval"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    participant_code: Mapped[str] = mapped_column(ForeignKey("participant.code"), index=True)
    hk_uuid: Mapped[str] = mapped_column(String(64))
    stage: Mapped[str] = mapped_column(String(16))
    start: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)
    end: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    source_identifier: Mapped[Optional[str]] = mapped_column(String(256), nullable=True)
    received_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    deleted_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("participant_code", "hk_uuid", name="uq_sleep_participant_uuid"),
    )


class ContextSample(Base):
    """Scalar quantity samples kept for context: Apple's own SDNN, heart rate, respiratory rate."""

    __tablename__ = "context_sample"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    participant_code: Mapped[str] = mapped_column(ForeignKey("participant.code"), index=True)
    hk_uuid: Mapped[str] = mapped_column(String(64))
    type: Mapped[str] = mapped_column(String(64), index=True)
    start: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)
    end: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    value: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(32))
    source_identifier: Mapped[Optional[str]] = mapped_column(String(256), nullable=True)
    received_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    deleted_at: Mapped[Optional[dt.datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("participant_code", "hk_uuid", "type", name="uq_context_participant_uuid"),
    )


class NightAnalysis(Base):
    """A derived night summary, keyed by the configuration that produced it.

    Append-only on purpose: re-running the analysis with a different artifact ceiling or a
    different aggregation window writes a new row. Nothing is overwritten, so a result can
    always be traced to the settings behind it.
    """

    __tablename__ = "night_analysis"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    participant_code: Mapped[str] = mapped_column(ForeignKey("participant.code"), index=True)
    night_of: Mapped[str] = mapped_column(String(10), index=True)  # yyyy-MM-dd, local to the participant
    config_hash: Mapped[str] = mapped_column(String(64), index=True)
    hrvkit_version: Mapped[str] = mapped_column(String(32))
    analysed_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    # The full NightSummary as the device computed it, plus the configuration itself.
    summary: Mapped[dict[str, Any]] = mapped_column(JSON)
    config: Mapped[dict[str, Any]] = mapped_column(JSON)

    __table_args__ = (
        UniqueConstraint(
            "participant_code", "night_of", "config_hash", name="uq_night_participant_date_config"
        ),
    )


class AccessLog(Base):
    """Every researcher read. IRBs ask who looked at what and when; this answers it."""

    __tablename__ = "access_log"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    token_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    token_label: Mapped[str] = mapped_column(String(128), default="")
    scope: Mapped[str] = mapped_column(String(16))
    endpoint: Mapped[str] = mapped_column(String(256))
    participant_code: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    row_count: Mapped[int] = mapped_column(Integer, default=0)


_connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
engine = create_engine(settings.database_url, connect_args=_connect_args, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)


def init_db() -> None:
    Base.metadata.create_all(engine)
