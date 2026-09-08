from __future__ import annotations

import datetime as dt

from sqlalchemy import select

from nocturne_sync import cli
from nocturne_sync.auth import hash_token
from nocturne_sync.db import (
    HeartbeatSeries,
    Participant,
    SessionLocal,
    Study,
    Token,
    utcnow,
)

from .conftest import auth, envelope, make_series

T0 = dt.datetime(2026, 3, 1, 23, 30, tzinfo=dt.timezone.utc)


def test_create_study_and_participants(capsys):
    assert cli.main(["create-study", "S9", "--name", "Tactical readiness"]) == 0
    assert cli.main(["add-participants", "--study", "S9", "--count", "3", "--prefix", "TAC"]) == 0

    out = capsys.readouterr().out
    lines = [l for l in out.strip().splitlines() if "," in l]
    assert lines[0] == "participant_code,enrolment_secret"
    codes = [l.split(",")[0] for l in lines[1:]]
    assert codes == ["TAC001", "TAC002", "TAC003"]

    # Secrets are printed once and stored only as hashes.
    secrets = [l.split(",")[1] for l in lines[1:]]
    with SessionLocal() as db:
        for code, secret in zip(codes, secrets):
            row = db.get(Participant, code)
            assert row.enrolment_secret_hash == hash_token(secret)
            assert secret not in row.enrolment_secret_hash


def test_created_participants_can_actually_enrol(client, capsys):
    cli.main(["create-study", "S9"])
    cli.main(["add-participants", "--study", "S9", "--count", "1", "--prefix", "E"])
    line = [l for l in capsys.readouterr().out.strip().splitlines() if l.startswith("E001")][0]
    code, secret = line.split(",")

    response = client.post(
        "/v1/enrol", json={"participant_code": code, "enrolment_secret": secret}
    )
    assert response.status_code == 200, response.text


def test_duplicate_study_is_refused():
    assert cli.main(["create-study", "S9"]) == 0
    assert cli.main(["create-study", "S9"]) == 1


def test_mint_and_revoke_researcher_token(client, capsys):
    cli.main(["create-study", "S9"])
    assert cli.main(["mint-researcher-token", "--label", "PI", "--study", "S9"]) == 0
    token = capsys.readouterr().out.strip().splitlines()[-1]

    assert client.get("/v1/participants", headers=auth(token)).status_code == 200
    assert cli.main(["revoke", token]) == 0
    assert client.get("/v1/participants", headers=auth(token)).status_code == 401


def test_expired_token_is_refused(client):
    cli.main(["create-study", "S9"])
    with SessionLocal() as db:
        db.add(
            Token(
                token_hash=hash_token("expired-token"),
                scope="researcher",
                study_id="S9",
                label="stale",
                expires_at=utcnow() - dt.timedelta(days=1),
            )
        )
        db.commit()
    assert client.get("/v1/participants", headers=auth("expired-token")).status_code == 401


def test_withdraw_revokes_tokens_and_keeps_data_by_default(client, device_token, participant):
    assert client.post(
        "/v1/ingest", json=envelope(series=[make_series(T0)]), headers=auth(device_token)
    ).status_code == 200

    assert cli.main(["withdraw", participant["code"]]) == 0

    # The device can no longer post.
    assert client.post(
        "/v1/ingest", json=envelope(series=[make_series(T0 + dt.timedelta(days=1))]),
        headers=auth(device_token),
    ).status_code == 401

    # Data already collected is retained unless the purge is asked for explicitly:
    # "you may withdraw" and "you may withdraw and have your data deleted" are different
    # promises and only the consent form knows which one was made.
    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 1
        assert db.get(Participant, participant["code"]).withdrawn_at is not None


def test_withdraw_with_purge_deletes_the_data(client, device_token, participant):
    client.post("/v1/ingest", json=envelope(series=[make_series(T0)]), headers=auth(device_token))
    assert cli.main(["withdraw", participant["code"], "--purge"]) == 0
    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 0


def test_prune_is_a_dry_run_unless_applied(client, device_token, participant, capsys):
    client.post(
        "/v1/ingest",
        json=envelope(series=[make_series(T0 - dt.timedelta(days=400), hk_uuid="ancient")]),
        headers=auth(device_token),
    )
    with SessionLocal() as db:
        db.get(Study, "S1").retention_days = 365
        db.commit()

    assert cli.main(["prune"]) == 0
    assert "would delete 1 rows" in capsys.readouterr().out
    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 1

    assert cli.main(["prune", "--apply"]) == 0
    assert "deleted 1 rows" in capsys.readouterr().out
    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 0


def test_prune_leaves_studies_without_a_retention_policy_alone(client, device_token, capsys):
    client.post(
        "/v1/ingest",
        json=envelope(series=[make_series(T0 - dt.timedelta(days=4000))]),
        headers=auth(device_token),
    )
    assert cli.main(["prune", "--apply"]) == 0
    assert "deleted 0 rows" in capsys.readouterr().out
    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 1
