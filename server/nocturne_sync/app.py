from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import SCHEMA_VERSION, __version__
from .db import init_db
from .ingest import router as ingest_router
from .query import router as query_router

@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(
    lifespan=lifespan,
    title="Nocturne Sync",
    version=__version__,
    description=(
        "Ingest and query API for Apple Health data collected from study participants. "
        "There is no Apple-side cloud API for Health data: every row here was read from "
        "HealthKit by an app running on a participant's own iPhone and posted to this "
        "service. Participants are opaque study codes; this service stores no PII."
    ),
)
app.include_router(ingest_router)
app.include_router(query_router)



@app.get("/health", tags=["meta"])
def health() -> dict[str, object]:
    return {"status": "ok", "version": __version__, "schema_version": SCHEMA_VERSION}
