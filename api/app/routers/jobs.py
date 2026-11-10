from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from psycopg.types.json import Jsonb

from app.db.connection import get_connection
from app.dependencies.auth import get_current_user


router = APIRouter(prefix="/api/jobs", tags=["jobs"])


class JobResponse(BaseModel):
    """Публичное представление фоновой задачи без исходного текста запроса."""
    jobId: UUID
    status: Literal["queued", "running", "completed", "failed", "expired"]
    result: Any | None
    errorCode: str | None
    createdAt: datetime
    startedAt: datetime | None
    finishedAt: datetime | None


# OP-09. GET /api/jobs/{job_id}
@router.get("/{job_id}", response_model=JobResponse)
def get_job(
    job_id: UUID,
    current_user: dict = Depends(get_current_user),
):
    # Владелец задачи и ADMIN могут получить состояние

    role = current_user["role"]
    if role not in ("USER", "ADMIN"):
        raise HTTPException(status_code=404, detail="Задача не найдена")

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """SELECT id, owner_user_id, status, result, error_code,
                          created_at, started_at, finished_at
                   FROM ai_jobs
                   WHERE id = %s
                     AND (owner_user_id = %s OR %s = 'ADMIN')""",
                (job_id, current_user["id"], role),
            )
            row = cursor.fetchone()

            # 404 для чужой и отсутствующей задачи
            if row is None:
                raise HTTPException(
                    status_code=404, detail="Задача не найдена")

            cursor.execute(
                """INSERT INTO audit_events
                       (actor_user_id, action, object_type, object_id, result, details)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (
                    current_user["id"],
                    "READ_AI_JOB",
                    "AI_JOB",
                    job_id,
                    "SUCCESS",
                    Jsonb({"status": str(row[2])}),
                ),
            )

    return {
        "jobId": row[0],
        "status": str(row[2]).lower(),
        "result": row[3],
        "errorCode": row[4],
        "createdAt": row[5],
        "startedAt": row[6],
        "finishedAt": row[7],
    }
