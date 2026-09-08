from __future__ import annotations

import datetime as dt

from nocturne_sync.db import HeartbeatSeries, NightAnalysis, Participant, SessionLocal, utcnow

from .conftest import auth, envelope, make_series

T0 = dt.datetime(2026, 3, 1, 23, 30, tzinfo=dt.timezone.utc)


def test_series_ingest_preserves_beats_and_gap_flags(client, device_token, researcher_token, participant):
    series = make_series(T0, beats=60, gap_at=30)
    response = client.post(
        "/v1/ingest", json=envelope(series=[series]), headers=auth(device_token)
    )
    assert response.status_code == 200, response.text
    assert response.json()["accepted"]["series"] == 1

    read = client.get(
        f"/v1/participants/{participant['code']}/series?include_beats=true",
        headers=auth(researcher_token),
    )
    assert read.status_code == 200
    stored = read.json()[0]
    assert stored["beat_count"] == 60
    assert stored["beats"][30]["precededByGap"] is True
    assert sum(1 for b in stored["beats"] if b["precededByGap"]) == 1
    # Offsets survive to microsecond precision, which matters: 1 ms of drift on a beat
    # timestamp is 1 ms of error in the interval either side of it.
    assert stored["beats"][30]["offset"] == round(30 * 1.02, 6)


def test_ingest_is_idempotent(client, device_token):
    """Background sync retries. Replaying an upload must not duplicate rows."""
    batch = envelope(series=[make_series(T0), make_series(T0 + dt.timedelta(hours=1))])

    first = client.post("/v1/ingest", json=batch, headers=auth(device_token)).json()
    assert first["accepted"]["series"] == 2 and first["duplicate"]["series"] == 0

    second = client.post("/v1/ingest", json=batch, headers=auth(device_token)).json()
    assert second["accepted"]["series"] == 0 and second["duplicate"]["series"] == 2

    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 2


def test_partial_overlap_only_inserts_the_new_rows(client, device_token):
    old = make_series(T0)
    client.post("/v1/ingest", json=envelope(series=[old]), headers=auth(device_token))
    mixed = client.post(
        "/v1/ingest",
        json=envelope(series=[old, make_series(T0 + dt.timedelta(hours=2))]),
        headers=auth(device_token),
    ).json()
    assert mixed["accepted"]["series"] == 1
    assert mixed["duplicate"]["series"] == 1


def test_participant_comes_from_the_token_not_the_body(client, device_token, study, researcher_token):
    """There is no participant field in the envelope by design, so a compromised device
    cannot attribute data to somebody else."""
    with SessionLocal() as db:
        db.add(Participant(code="P002", study_id=study))
        db.commit()

    client.post("/v1/ingest", json=envelope(series=[make_series(T0)]), headers=auth(device_token))

    mine = client.get("/v1/participants/P001/series", headers=auth(researcher_token)).json()
    theirs = client.get("/v1/participants/P002/series", headers=auth(researcher_token)).json()
    assert len(mine) == 1 and len(theirs) == 0


def test_naive_timestamps_are_rejected(client, device_token):
    """A sleep boundary recorded without an offset is unrecoverable later — you cannot
    tell whether 02:00 meant local or UTC, and night attribution turns on exactly that."""
    bad = make_series(T0)
    bad["start"] = "2026-03-01T23:30:00"
    response = client.post("/v1/ingest", json=envelope(series=[bad]), headers=auth(device_token))
    assert response.status_code == 422
    assert "offset" in response.text


def test_non_monotonic_beats_are_rejected(client, device_token):
    bad = make_series(T0, beats=10)
    bad["beats"][5]["offset"] = bad["beats"][4]["offset"]
    response = client.post("/v1/ingest", json=envelope(series=[bad]), headers=auth(device_token))
    assert response.status_code == 422
    assert "increasing" in response.text


def test_unsupported_schema_version_is_refused(client, device_token):
    response = client.post(
        "/v1/ingest", json={"schema_version": 99, "series": []}, headers=auth(device_token)
    )
    assert response.status_code == 422
    assert "schema_version" in response.text


def test_sleep_and_context_ingest(client, device_token, researcher_token, participant):
    body = envelope(
        sleep=[
            {
                "hk_uuid": "sleep-1",
                "stage": "deep",
                "start": T0.isoformat(),
                "end": (T0 + dt.timedelta(minutes=30)).isoformat(),
                "source_identifier": "com.apple.health",
            }
        ],
        context=[
            {
                "hk_uuid": "ctx-1",
                "type": "hrv_sdnn",
                "start": T0.isoformat(),
                "end": (T0 + dt.timedelta(seconds=60)).isoformat(),
                "value": 48.2,
                "unit": "ms",
            }
        ],
    )
    result = client.post("/v1/ingest", json=body, headers=auth(device_token)).json()
    assert result["accepted"]["sleep"] == 1
    assert result["accepted"]["context"] == 1

    sleep = client.get(
        f"/v1/participants/{participant['code']}/sleep", headers=auth(researcher_token)
    ).json()
    assert sleep[0]["stage"] == "deep"
    context = client.get(
        f"/v1/participants/{participant['code']}/context?type=hrv_sdnn",
        headers=auth(researcher_token),
    ).json()
    assert context[0]["value"] == 48.2


def test_sleep_interval_with_end_before_start_is_rejected(client, device_token):
    response = client.post(
        "/v1/ingest",
        json=envelope(
            sleep=[
                {
                    "hk_uuid": "sleep-bad",
                    "stage": "core",
                    "start": T0.isoformat(),
                    "end": (T0 - dt.timedelta(minutes=5)).isoformat(),
                }
            ]
        ),
        headers=auth(device_token),
    )
    assert response.status_code == 422


def test_deletion_tombstones_rather_than_removing(client, device_token, researcher_token, participant):
    """A sample deleted in Health should stop appearing in results but stay on record.
    "This series was withdrawn on date X" is something a reviewer can reasonably ask."""
    series = make_series(T0, hk_uuid="doomed-series")
    client.post("/v1/ingest", json=envelope(series=[series]), headers=auth(device_token))

    result = client.post(
        "/v1/ingest",
        json=envelope(deletions=[{"kind": "heartbeat_series", "hk_uuid": "doomed-series"}]),
        headers=auth(device_token),
    ).json()
    assert result["tombstoned"] == 1

    default = client.get(
        f"/v1/participants/{participant['code']}/series", headers=auth(researcher_token)
    ).json()
    assert default == []

    with_deleted = client.get(
        f"/v1/participants/{participant['code']}/series?include_deleted=true",
        headers=auth(researcher_token),
    ).json()
    assert len(with_deleted) == 1
    assert with_deleted[0]["deleted_at"] is not None

    with SessionLocal() as db:
        assert db.query(HeartbeatSeries).count() == 1


def test_reanalysis_under_a_new_config_appends_rather_than_overwrites(
    client, device_token, researcher_token, participant
):
    """The point of keying on the configuration hash: a night analysed twice under
    different preprocessing settings yields two traceable rows, not a silent overwrite."""
    def night(config_hash: str, rmssd: float, ceiling: float):
        return {
            "night_of": "2026-03-01",
            "config_hash": config_hash,
            "hrvkit_version": "0.1.0",
            "analysed_at": utcnow().isoformat(),
            "summary": {"rmssd": rmssd, "lnRMSSD": 3.9, "quality": "good", "alternates": {}},
            "config": {"qualityArtifactCeiling": ceiling},
        }

    client.post(
        "/v1/ingest", json=envelope(nights=[night("cfg-strict", 42.0, 0.05)]), headers=auth(device_token)
    )
    client.post(
        "/v1/ingest", json=envelope(nights=[night("cfg-loose", 47.5, 0.15)]), headers=auth(device_token)
    )
    # Re-posting the first is still a duplicate.
    again = client.post(
        "/v1/ingest", json=envelope(nights=[night("cfg-strict", 42.0, 0.05)]), headers=auth(device_token)
    ).json()
    assert again["duplicate"]["nights"] == 1

    nights = client.get(
        f"/v1/participants/{participant['code']}/nights", headers=auth(researcher_token)
    ).json()
    assert len(nights) == 2
    assert {n["config_hash"] for n in nights} == {"cfg-strict", "cfg-loose"}

    pinned = client.get(
        f"/v1/participants/{participant['code']}/nights?config_hash=cfg-loose",
        headers=auth(researcher_token),
    ).json()
    assert len(pinned) == 1 and pinned[0]["summary"]["rmssd"] == 47.5

    with SessionLocal() as db:
        assert db.query(NightAnalysis).count() == 2


def test_withdrawn_participant_cannot_ingest(client, device_token, participant):
    with SessionLocal() as db:
        db.get(Participant, participant["code"]).withdrawn_at = utcnow()
        db.commit()
    response = client.post(
        "/v1/ingest", json=envelope(series=[make_series(T0)]), headers=auth(device_token)
    )
    assert response.status_code == 410


def test_sync_state_lets_a_reinstalled_device_resume(client, device_token):
    """After a reinstall the app has lost its HealthKit anchors. Without this it would
    re-upload everything it can still see."""
    client.post(
        "/v1/ingest",
        json=envelope(series=[make_series(T0, hk_uuid="a"), make_series(T0 + dt.timedelta(days=1), hk_uuid="b")]),
        headers=auth(device_token),
    )
    state = client.get(
        "/v1/sync/state",
        params={"since": (T0 - dt.timedelta(days=7)).isoformat()},
        headers=auth(device_token),
    ).json()
    assert state["series_count"] == 2
    assert set(state["known_series_uuids"]) == {"a", "b"}
    assert state["latest_series_start"].startswith("2026-03-02")


def test_query_bounds_tolerate_an_unencoded_plus_and_a_bare_date(client, device_token):
    """`?from=2026-03-01T00:00:00+00:00` loses its "+" to form decoding unless the client
    percent-encodes it. Repairing that is unambiguous and saves an afternoon."""
    client.post("/v1/ingest", json=envelope(series=[make_series(T0)]), headers=auth(device_token))
    headers = auth(device_token)

    unencoded = client.get("/v1/sync/state?since=2026-02-22T23:30:00 00:00", headers=headers)
    assert unencoded.status_code == 200, unencoded.text
    assert unencoded.json()["series_count"] == 1

    for form in ("2026-02-22T23:30:00Z", "2026-02-22", "2026-02-22T23:30:00%2B00:00"):
        response = client.get(f"/v1/sync/state?since={form}", headers=headers)
        assert response.status_code == 200, f"{form}: {response.text}"
        assert response.json()["known_series_uuids"], form
