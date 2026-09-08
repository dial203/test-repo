from __future__ import annotations

import datetime as dt
import math

from nocturne_sync.db import SessionLocal, utcnow

from .conftest import auth, envelope

BASE = dt.datetime(2026, 9, 8, 12, 0, tzinfo=dt.timezone.utc)


def night(night_of: str, rmssd: float, config_hash: str = "ad03842e11fa51a1",
          analysed_at: dt.datetime | None = None, sources=None, quality="good"):
    return {
        "night_of": night_of,
        "config_hash": config_hash,
        "hrvkit_version": "0.1.0",
        "analysed_at": (analysed_at or BASE).isoformat(),
        "sources": sources if sources is not None else ["com.apple.health"],
        "summary": {
            "rmssd": rmssd,
            "lnRMSSD": math.log(rmssd) if rmssd > 0 else float("nan"),
            "sdnn": rmssd * 1.4,
            "meanHR": 52.0,
            "minHR": 47.0,
            "pnn50": 31.0,
            "sd1": rmssd * 0.7,
            "sd2": rmssd * 1.9,
            "quality": quality,
            "coverage": 780.0,
            "artifactFraction": 0.012,
            "usedWindowCount": 13,
            "alternates": {},
        },
        "config": {"qualityArtifactCeiling": 0.05},
    }


def test_metrics_returns_one_flat_row_per_night(client, device_token, researcher_token):
    assert client.post(
        "/v1/ingest",
        json=envelope(nights=[night("2026-09-06", 44.0), night("2026-09-07", 51.5)]),
        headers=auth(device_token),
    ).status_code == 200

    rows = client.get("/v1/metrics", headers=auth(researcher_token)).json()
    assert len(rows) == 2
    row = rows[0]

    # Flat scalars, units in the names, joinable key.
    assert row["participant_code"] == "P001"
    assert row["night_of"] == "2026-09-06"
    assert row["rmssd_ms"] == 44.0
    assert row["sdnn_ms"] == 44.0 * 1.4
    assert row["mean_hr_bpm"] == 52.0
    assert row["window_count"] == 13
    assert row["quality"] == "good"
    assert row["sources"] == ["com.apple.health"]
    assert row["config_hash"] == "ad03842e11fa51a1"
    assert row["aggregation"] == "median_of_windows"
    assert row["revision_count"] == 1
    # No nested blob to dig through.
    assert "summary" not in row and "alternates" not in row


def test_date_window_filters_by_night_of(client, device_token, researcher_token):
    client.post(
        "/v1/ingest",
        json=envelope(nights=[
            night("2026-09-01", 40.0), night("2026-09-08", 45.0), night("2026-09-20", 50.0)
        ]),
        headers=auth(device_token),
    )
    rows = client.get(
        "/v1/metrics", params={"from": "2026-09-05", "to": "2026-09-10"},
        headers=auth(researcher_token),
    ).json()
    assert [r["night_of"] for r in rows] == ["2026-09-08"]


def test_revisions_collapse_to_the_latest_by_default(client, device_token, researcher_token):
    """A re-analysed night must not appear twice to a polling consumer, and must not be
    silently averaged either."""
    client.post(
        "/v1/ingest",
        json=envelope(nights=[night("2026-09-07", 44.0, config_hash="aaaaaaaaaaaaaaaa",
                                    analysed_at=BASE)]),
        headers=auth(device_token),
    )
    client.post(
        "/v1/ingest",
        json=envelope(nights=[night("2026-09-07", 51.0, config_hash="bbbbbbbbbbbbbbbb",
                                    analysed_at=BASE + dt.timedelta(hours=2))]),
        headers=auth(device_token),
    )

    default = client.get("/v1/metrics", headers=auth(researcher_token)).json()
    assert len(default) == 1
    assert default[0]["rmssd_ms"] == 51.0, "should be the most recently analysed"
    assert default[0]["config_hash"] == "bbbbbbbbbbbbbbbb"
    assert default[0]["revision_count"] == 2, "the consumer must be able to see there are others"

    every = client.get(
        "/v1/metrics", params={"all_revisions": "true"}, headers=auth(researcher_token)
    ).json()
    assert len(every) == 2
    assert sorted(r["rmssd_ms"] for r in every) == [44.0, 51.0]

    pinned = client.get(
        "/v1/metrics", params={"config_hash": "aaaaaaaaaaaaaaaa"}, headers=auth(researcher_token)
    ).json()
    assert len(pinned) == 1 and pinned[0]["rmssd_ms"] == 44.0


def test_nan_metrics_become_null_not_a_number(client, device_token, researcher_token):
    """An empty or unreportable night has no RMSSD. JSON has no NaN, and a consumer
    reading one as a value would be worse than a null."""
    # This is the form the Swift client actually sends: JSON has no NaN literal, so
    # `Export.json` encodes non-finite doubles as strings.
    empty = night("2026-09-09", 1.0, quality="insufficient")
    empty["summary"]["rmssd"] = "NaN"
    empty["summary"]["lnRMSSD"] = "NaN"
    empty["summary"]["sd2"] = "-Infinity"
    assert client.post(
        "/v1/ingest", json=envelope(nights=[empty]), headers=auth(device_token)
    ).status_code == 200

    row = client.get("/v1/metrics", headers=auth(researcher_token)).json()[0]
    assert row["rmssd_ms"] is None, "the string \"NaN\" must not reach a consumer"
    assert row["ln_rmssd"] is None
    assert row["sd2_ms"] is None
    assert row["quality"] == "insufficient"
    # Other fields still come through.
    assert row["mean_hr_bpm"] == 52.0


def test_a_bare_json_null_is_also_treated_as_absent(client, device_token, researcher_token):
    payload = night("2026-09-10", 44.0)
    payload["summary"]["rmssd"] = None
    payload["summary"]["pnn50"] = True          # a wrong type must not become 1.0
    assert client.post(
        "/v1/ingest", json=envelope(nights=[payload]), headers=auth(device_token)
    ).status_code == 200
    row = client.get("/v1/metrics", headers=auth(researcher_token)).json()[0]
    assert row["rmssd_ms"] is None
    assert row["pnn50_pct"] is None


def test_metrics_requires_a_researcher_token(client, device_token):
    assert client.get("/v1/metrics", headers=auth(device_token)).status_code == 403
    assert client.get("/v1/metrics").status_code == 401
    assert client.get("/v1/metrics.csv", headers=auth(device_token)).status_code == 403


def test_metrics_csv_matches_the_json_feed(client, device_token, researcher_token):
    client.post(
        "/v1/ingest",
        json=envelope(nights=[night("2026-09-06", 44.0), night("2026-09-07", 51.5)]),
        headers=auth(device_token),
    )
    response = client.get("/v1/metrics.csv", headers=auth(researcher_token))
    assert response.status_code == 200
    lines = response.text.strip().splitlines()
    header = lines[0].split(",")
    assert header[:3] == ["participant_code", "night_of", "rmssd_ms"]
    assert "config_hash" in header
    assert len(lines) == 3
    assert lines[1].split(",")[2] == "44.0"


def test_study_scoping_applies_to_the_metrics_feed(client, researcher_token, participant):
    from nocturne_sync.db import Participant, Study

    with SessionLocal() as db:
        db.add(Study(id="S2", name="Other"))
        db.add(Participant(code="Q001", study_id="S2"))
        db.commit()
    assert client.get(
        "/v1/metrics", params={"participant": "Q001"}, headers=auth(researcher_token)
    ).status_code == 403


def test_sources_default_to_empty_for_clients_that_omit_them(client, device_token, researcher_token):
    payload = night("2026-09-06", 44.0)
    del payload["sources"]
    assert client.post(
        "/v1/ingest", json=envelope(nights=[payload]), headers=auth(device_token)
    ).status_code == 200
    row = client.get("/v1/metrics", headers=auth(researcher_token)).json()[0]
    assert row["sources"] == []
