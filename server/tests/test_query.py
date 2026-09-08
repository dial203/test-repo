from __future__ import annotations

import datetime as dt

from nocturne_sync.auth import mint_token
from nocturne_sync.db import Participant, SessionLocal, Study, Token, utcnow

from .conftest import auth, envelope, make_series

T0 = dt.datetime(2026, 3, 1, 23, 30, tzinfo=dt.timezone.utc)


def _night(night_of: str, rmssd: float, config_hash: str = "a1b2c3d4e5f60718"):
    return {
        "night_of": night_of,
        "config_hash": config_hash,
        "hrvkit_version": "0.1.0",
        "analysed_at": utcnow().isoformat(),
        "summary": {
            "rmssd": rmssd,
            "lnRMSSD": round(__import__("math").log(rmssd), 4),
            "sdnn": rmssd * 1.4,
            "meanHR": 52.0,
            "minHR": 47.0,
            "pnn50": 31.0,
            "sd1": rmssd * 0.7,
            "sd2": rmssd * 1.9,
            "quality": "good",
            "coverage": 780.0,
            "artifactFraction": 0.012,
            "usedWindowCount": 13,
            "alternates": {"rmssd.median": rmssd, "rmssd.deep": rmssd * 1.1},
        },
        "config": {"qualityArtifactCeiling": 0.05},
    }


def test_beats_csv_streams_one_row_per_beat(client, device_token, researcher_token, participant):
    assert client.post(
        "/v1/ingest",
        json=envelope(
            series=[
                make_series(T0, beats=60, gap_at=30, hk_uuid="s1"),
                make_series(T0 + dt.timedelta(hours=1), beats=55, hk_uuid="s2"),
            ]
        ),
        headers=auth(device_token),
    ).status_code == 200
    response = client.get(
        f"/v1/participants/{participant['code']}/beats.csv", headers=auth(researcher_token)
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/csv")
    assert "beats-P001.csv" in response.headers["content-disposition"]

    lines = response.text.strip().splitlines()
    assert lines[0].startswith("participant_code,series_uuid,")
    assert len(lines) == 1 + 60 + 55

    rows = [line.split(",") for line in lines[1:]]
    gap_column = lines[0].split(",").index("preceded_by_gap")
    assert sum(1 for r in rows if r[gap_column] == "1") == 1
    # Absolute times must be reconstructed from the series start plus the beat offset.
    assert rows[0][lines[0].split(",").index("absolute_time_iso")].startswith("2026-03-01T23:30:00")


def test_beats_csv_respects_the_time_window(client, device_token, researcher_token, participant):
    assert client.post(
        "/v1/ingest",
        json=envelope(
            series=[
                make_series(T0, beats=10, hk_uuid="inside"),
                make_series(T0 + dt.timedelta(days=5), beats=10, hk_uuid="outside"),
            ]
        ),
        headers=auth(device_token),
    ).status_code == 200
    response = client.get(
        f"/v1/participants/{participant['code']}/beats.csv",
        params={"from": T0.isoformat(), "to": (T0 + dt.timedelta(days=1)).isoformat()},
        headers=auth(researcher_token),
    )
    assert "inside" in response.text
    assert "outside" not in response.text


def test_nights_csv_is_analysis_ready(client, device_token, researcher_token):
    assert client.post(
        "/v1/ingest",
        json=envelope(nights=[_night("2026-03-01", 44.0), _night("2026-03-02", 51.5)]),
        headers=auth(device_token),
    ).status_code == 200
    response = client.get("/v1/export/nights.csv", headers=auth(researcher_token))
    assert response.status_code == 200
    lines = response.text.strip().splitlines()
    header = lines[0].split(",")

    for column in ("participant_code", "night_of", "config_hash", "rmssd", "lnRMSSD"):
        assert column in header
    # Alternative aggregations are flattened into their own columns.
    assert "alt_rmssd_median" in header
    assert "alt_rmssd_deep" in header
    assert len(lines) == 3

    rmssd = header.index("rmssd")
    assert sorted(line.split(",")[rmssd] for line in lines[1:]) == ["44.0", "51.5"]


def test_deleted_series_are_excluded_from_bulk_export(client, device_token, researcher_token, participant):
    assert client.post(
        "/v1/ingest",
        json=envelope(series=[make_series(T0, beats=10, hk_uuid="gone")]),
        headers=auth(device_token),
    ).status_code == 200
    assert client.post(
        "/v1/ingest",
        json=envelope(deletions=[{"kind": "heartbeat_series", "hk_uuid": "gone"}]),
        headers=auth(device_token),
    ).status_code == 200
    response = client.get(
        f"/v1/participants/{participant['code']}/beats.csv", headers=auth(researcher_token)
    )
    assert len(response.text.strip().splitlines()) == 1  # header only


def test_study_scoped_token_cannot_read_another_study(client, researcher_token, participant):
    """A collaborator on trial A must not be able to read trial B."""
    with SessionLocal() as db:
        db.add(Study(id="S2", name="Other trial"))
        db.add(Participant(code="Q001", study_id="S2"))
        db.commit()

    assert client.get("/v1/participants/Q001/series", headers=auth(researcher_token)).status_code == 403
    listed = client.get("/v1/participants", headers=auth(researcher_token)).json()
    assert [p["participant_code"] for p in listed] == ["P001"]


def test_unscoped_researcher_token_sees_every_study(client, participant):
    with SessionLocal() as db:
        db.add(Study(id="S2", name="Other trial"))
        db.add(Participant(code="Q001", study_id="S2"))
        plaintext, digest = mint_token()
        db.add(Token(token_hash=digest, scope="researcher", study_id=None, label="admin"))
        db.commit()
    listed = client.get("/v1/participants", headers=auth(plaintext)).json()
    assert {p["participant_code"] for p in listed} == {"P001", "Q001"}


def test_unknown_participant_is_404(client, researcher_token):
    assert client.get("/v1/participants/NOPE/series", headers=auth(researcher_token)).status_code == 404


def test_reads_are_written_to_the_audit_log(client, device_token, researcher_token, participant):
    assert client.post(
        "/v1/ingest", json=envelope(series=[make_series(T0, beats=12)]), headers=auth(device_token)
    ).status_code == 200
    client.get(f"/v1/participants/{participant['code']}/beats.csv", headers=auth(researcher_token))

    audit = client.get("/v1/audit", headers=auth(researcher_token)).json()
    entry = next(e for e in audit if e["endpoint"].endswith("beats.csv"))
    assert entry["scope"] == "researcher"
    assert entry["token_label"] == "PI"
    assert entry["participant_code"] == "P001"
    assert entry["row_count"] == 12


def test_page_size_is_capped(client, researcher_token, participant):
    over = client.get(
        f"/v1/participants/{participant['code']}/series?limit=5000", headers=auth(researcher_token)
    )
    assert over.status_code == 422


def test_beats_are_not_returned_by_default(client, device_token, researcher_token, participant):
    """Pulling a year of chest-strap beats into a JSON list should take a deliberate flag."""
    assert client.post(
        "/v1/ingest", json=envelope(series=[make_series(T0, beats=60)]), headers=auth(device_token)
    ).status_code == 200
    default = client.get(
        f"/v1/participants/{participant['code']}/series", headers=auth(researcher_token)
    ).json()
    assert "beats" not in default[0]
    assert default[0]["beat_count"] == 60


def test_health_endpoint_needs_no_auth(client):
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert body["schema_version"] == 1
