from __future__ import annotations

from nocturne_sync.auth import hash_token
from nocturne_sync.db import Participant, SessionLocal, Token

from .conftest import auth


def test_enrolment_returns_a_device_token(client, participant):
    response = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": participant["secret"]},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["participant_code"] == "P001"
    assert len(body["device_token"]) > 30

    # Only the hash is persisted.
    with SessionLocal() as db:
        row = db.query(Token).one()
        assert row.token_hash == hash_token(body["device_token"])
        assert body["device_token"] not in row.token_hash


def test_enrolment_secret_is_single_use(client, participant):
    first = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": participant["secret"]},
    )
    assert first.status_code == 200
    second = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": participant["secret"]},
    )
    assert second.status_code == 409


def test_unknown_code_and_wrong_secret_are_indistinguishable(client, participant):
    """A caller must not be able to tell which participant codes exist."""
    wrong_secret = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": "wrong-secret-x"},
    )
    unknown_code = client.post(
        "/v1/enrol",
        json={"participant_code": "P999", "enrolment_secret": "wrong-secret-x"},
    )
    assert wrong_secret.status_code == unknown_code.status_code == 401
    assert wrong_secret.json() == unknown_code.json()


def test_enrolment_locks_after_repeated_failures(client, participant):
    for _ in range(5):
        assert client.post(
            "/v1/enrol",
            json={"participant_code": participant["code"], "enrolment_secret": "bad-secret-000"},
        ).status_code == 401
    # Even the correct secret is now refused.
    locked = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": participant["secret"]},
    )
    assert locked.status_code == 429


def test_withdrawn_participant_cannot_enrol(client, participant):
    from nocturne_sync.db import utcnow

    with SessionLocal() as db:
        row = db.get(Participant, participant["code"])
        row.withdrawn_at = utcnow()
        db.commit()
    response = client.post(
        "/v1/enrol",
        json={"participant_code": participant["code"], "enrolment_secret": participant["secret"]},
    )
    assert response.status_code == 410


def test_device_token_cannot_read_the_study(client, device_token, participant):
    """The single most important authorisation boundary: a participant's phone holds a
    write credential and must not be able to read anyone's data, including its own."""
    for path in (
        "/v1/participants",
        f"/v1/participants/{participant['code']}/series",
        f"/v1/participants/{participant['code']}/nights",
        "/v1/export/nights.csv",
    ):
        response = client.get(path, headers=auth(device_token))
        assert response.status_code == 403, f"{path} leaked to a device token"


def test_researcher_token_cannot_ingest(client, researcher_token):
    response = client.post("/v1/ingest", json={"schema_version": 1}, headers=auth(researcher_token))
    assert response.status_code == 403


def test_no_token_is_rejected(client):
    assert client.post("/v1/ingest", json={"schema_version": 1}).status_code == 401
    assert client.get("/v1/participants").status_code == 401
    assert client.get("/v1/participants", headers=auth("not-a-real-token")).status_code == 401


def test_revoked_token_stops_working(client, device_token):
    from nocturne_sync.db import utcnow

    with SessionLocal() as db:
        row = db.query(Token).one()
        row.revoked_at = utcnow()
        db.commit()
    assert client.get("/v1/sync/state", headers=auth(device_token)).status_code == 401
