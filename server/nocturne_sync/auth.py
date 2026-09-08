"""Token minting and request authentication.

Tokens are 256 bits of `secrets.token_urlsafe` entropy, stored as a SHA-256 digest. A
password KDF (bcrypt, argon2) buys nothing here: the point of a slow hash is to resist
guessing a low-entropy human secret, and there is nothing to guess in a 256-bit random
string. What matters is that the plaintext is never stored, comparison is constant-time,
and the digest is useless if the database leaks.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from typing import Optional

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .db import AccessLog, Participant, SessionLocal, Token, utcnow

TOKEN_BYTES = 32


def epoch(value: Optional[dt.datetime]) -> Optional[dt.datetime]:
    """Re-attach UTC to a datetime read back from the database.

    SQLite has no native timestamp type, so SQLAlchemy returns naive datetimes even for a
    `DateTime(timezone=True)` column. Postgres returns aware ones. Comparing a naive value
    to an aware one raises, so any stored timestamp that gets compared or serialised in
    Python goes through here first — otherwise the code works on Postgres and throws on
    SQLite, which is the worst way for this to fail.
    """
    if value is None:
        return None
    return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)


def mint_token() -> tuple[str, str]:
    """Return (plaintext, digest). The plaintext is shown once and never stored."""
    plaintext = secrets.token_urlsafe(TOKEN_BYTES)
    return plaintext, hash_token(plaintext)


def hash_token(plaintext: str) -> str:
    return hashlib.sha256(plaintext.encode("utf-8")).hexdigest()


def secret_matches(plaintext: str, digest: str) -> bool:
    return hmac.compare_digest(hash_token(plaintext), digest)


def get_db() -> Session:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@dataclass
class Principal:
    token_id: int
    scope: str
    label: str
    study_id: Optional[str]
    participant_code: Optional[str]


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def authenticate(
    request: Request,
    authorization: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
) -> Principal:
    if settings.require_https and request.url.scheme != "https":
        # Health data over cleartext is not a warning-level problem.
        forwarded = request.headers.get("x-forwarded-proto")
        if forwarded != "https":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="HTTPS required. Set NOCTURNE_REQUIRE_HTTPS=0 only for local development.",
            )

    if not authorization or not authorization.startswith("Bearer "):
        raise _unauthorized("Bearer token required")

    row = db.scalar(select(Token).where(Token.token_hash == hash_token(authorization[7:].strip())))
    if row is None:
        raise _unauthorized("Unknown token")
    if row.revoked_at is not None:
        raise _unauthorized("Token revoked")
    if (expires := epoch(row.expires_at)) is not None and expires < utcnow():
        raise _unauthorized("Token expired")

    row.last_used_at = utcnow()
    db.commit()
    return Principal(row.id, row.scope, row.label, row.study_id, row.participant_code)


def require_device(principal: Principal = Depends(authenticate)) -> Principal:
    if principal.scope != "device" or principal.participant_code is None:
        raise HTTPException(status_code=403, detail="Device token required")
    return principal


def require_researcher(principal: Principal = Depends(authenticate)) -> Principal:
    """Researcher scope. A device token is explicitly refused here — a participant's phone
    must never be able to read the study."""
    if principal.scope != "researcher":
        raise HTTPException(status_code=403, detail="Researcher token required")
    return principal


def assert_active(db: Session, code: str) -> Participant:
    participant = db.get(Participant, code)
    if participant is None:
        raise HTTPException(status_code=404, detail="Unknown participant")
    if participant.withdrawn_at is not None:
        raise HTTPException(status_code=410, detail="Participant has withdrawn")
    return participant


def researcher_may_read(db: Session, principal: Principal, code: str) -> Participant:
    participant = db.get(Participant, code)
    if participant is None:
        raise HTTPException(status_code=404, detail="Unknown participant")
    if principal.study_id is not None and participant.study_id != principal.study_id:
        # Scoping a token to one study keeps a collaborator on trial A out of trial B.
        raise HTTPException(status_code=403, detail="Token is not scoped to this participant's study")
    return participant


def log_access(
    db: Session,
    principal: Principal,
    endpoint: str,
    participant_code: Optional[str],
    row_count: int,
) -> None:
    db.add(
        AccessLog(
            at=utcnow(),
            token_id=principal.token_id,
            token_label=principal.label,
            scope=principal.scope,
            endpoint=endpoint,
            participant_code=participant_code,
            row_count=row_count,
        )
    )
    db.commit()


