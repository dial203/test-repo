from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str = os.environ.get("NOCTURNE_DATABASE_URL", "sqlite:///./nocturne.db")
    # Largest accepted upload body. A night of passive Apple Watch data is a few hundred
    # kilobytes; a night of continuous chest-strap RR is a few megabytes.
    max_upload_bytes: int = int(os.environ.get("NOCTURNE_MAX_UPLOAD_BYTES", 32 * 1024 * 1024))
    # Enrolment attempts allowed per participant code before it locks.
    max_enrolment_attempts: int = int(os.environ.get("NOCTURNE_MAX_ENROLMENT_ATTEMPTS", 5))
    # Set false only for local development against a tunnel.
    require_https: bool = os.environ.get("NOCTURNE_REQUIRE_HTTPS", "1") == "1"


settings = Settings()
