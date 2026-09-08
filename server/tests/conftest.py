from __future__ import annotations

import datetime as dt
import os
import tempfile
import uuid

import pytest

# Must be set before nocturne_sync.db imports settings.
_tmpdir = tempfile.mkdtemp()
os.environ["NOCTURNE_DATABASE_URL"] = f"sqlite:///{_tmpdir}/test.db"
os.environ["NOCTURNE_REQUIRE_HTTPS"] = "0"

from fastapi.testclient import TestClient  # noqa: E402

from nocturne_sync.app import app  # noqa: E402
from nocturne_sync.auth import hash_token, mint_token  # noqa: E402
from nocturne_sync.db import Base, Participant, SessionLocal, Study, Token, engine, init_db  # noqa: E402


@pytest.fixture(autouse=True)
def clean_db():
    Base.metadata.drop_all(engine)
    init_db()
    yield


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def study():
    with SessionLocal() as db:
        db.add(Study(id="S1", name="Overnight HRV validation"))
        db.commit()
    return "S1"


@pytest.fixture
def participant(study):
    """A participant code plus its one-time enrolment secret."""
    secret = "enrol-secret-12345"
    with SessionLocal() as db:
        db.add(Participant(code="P001", study_id=study, enrolment_secret_hash=hash_token(secret)))
        db.commit()
    return {"code": "P001", "secret": secret}


@pytest.fixture
def device_token(client, participant):
    response = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": participant["secret"]},
    )
    assert response.status_code == 200, response.text
    return response.json()["device_token"]


@pytest.fixture
def researcher_token(study):
    plaintext, digest = mint_token()
    with SessionLocal() as db:
        db.add(Token(token_hash=digest, scope="researcher", study_id=study, label="PI"))
        db.commit()
    return plaintext


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def make_series(start: dt.datetime, beats: int = 60, gap_at: int | None = None, hk_uuid: str | None = None):
    """A synthetic HKHeartbeatSeriesSample-shaped payload, ~1 s intervals."""
    return {
        "hk_uuid": hk_uuid or str(uuid.uuid4()),
        "start": start.isoformat(),
        "beats": [
            {"offset": round(i * 1.02, 6), "precededByGap": (gap_at is not None and i == gap_at)}
            for i in range(beats)
        ],
        "source_identifier": "com.apple.health",
        "device_name": "Apple Watch",
    }


def envelope(**kwargs):
    body = {"schema_version": 1, "device": {"model": "iPhone16,2", "app_version": "0.1.0"}}
    body.update(kwargs)
    return body
