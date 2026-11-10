import logging
import os
from uuid import uuid4

from fastapi import FastAPI, Header, HTTPException, Request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("calendar")

API_KEY = os.environ.get("CALENDAR_API_KEY", "").strip()
if not API_KEY:
    raise RuntimeError("CALENDAR_API_KEY is required")

# Идемпотентность заглушки: тот же (scheduleEntryId, action) → тот же externalEventId.
STATE: dict[tuple[str, str], str] = {}

app = FastAPI(title="Calendar Service (stub)")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/api/v1/events", status_code=201)
async def upsert_event(
    request: Request,
    x_api_key: str | None = Header(default=None, alias="X-Api-Key"),
):
    if not x_api_key or x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

    body = await request.json()
    for field in ("scheduleEntryId", "action"):
        if field not in body:
            raise HTTPException(status_code=400, detail=f"Missing {field}")
    if body["action"] not in ("upsert", "delete"):
        raise HTTPException(status_code=400, detail="Invalid action")

    key = (str(body["scheduleEntryId"]), body["action"])
    if key in STATE:
        log.info("replay scheduleEntryId=%s action=%s externalEventId=%s", *key, STATE[key])
        return {"externalEventId": STATE[key], "status": "replayed"}

    ext = f"cal-{uuid4()}"
    STATE[key] = ext
    log.info("accept scheduleEntryId=%s action=%s externalEventId=%s",
             body["scheduleEntryId"], body["action"], ext)
    return {"externalEventId": ext, "status": "created"}