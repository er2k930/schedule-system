import hmac
import os
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Query

from app.db.connection import get_connection


router = APIRouter(
    prefix="/internal",
    tags=["internal"],
)


@router.get("/schedule/{schedule_id}/notification")
def get_notification_data(
    schedule_id: UUID,
    x_worker_token: str | None = Header(default=None),
    event_type: str = Query(default="SCHEDULE_UPDATED"),
):
    expected_token = os.getenv("WORKER_TOKEN", "")

    if (
        not expected_token
        or not x_worker_token
        or not hmac.compare_digest(x_worker_token, expected_token)
    ):
        raise HTTPException(
            status_code=403,
            detail="Доступ запрещён",
        )

    allowed_events = {
        "SCHEDULE_UPDATED",
        "SCHEDULE_PUBLISHED",
        "SCHEDULE_CANCELLED",
    }

    if event_type not in allowed_events:
        raise HTTPException(
            status_code=400,
            detail="Неизвестный тип события",
        )

    with get_connection() as connection:
        with connection.cursor() as cursor:

            # Получаем данные занятия
            cursor.execute(
                """
                SELECT
                    s.id,
                    s.status,
                    s.starts_at,
                    s.ends_at,
                    sub.name,
                    g.name,
                    r.building,
                    r.room_number,
                    t.full_name
                FROM schedule_entries s
                JOIN subjects sub ON sub.id = s.subject_id
                JOIN groups g ON g.id = s.group_id
                JOIN rooms r ON r.id = s.room_id
                LEFT JOIN users t ON t.id = s.teacher_id
                WHERE s.id = %s
                """,
                (schedule_id,),
            )

            row = cursor.fetchone()

            if row is None:
                raise HTTPException(
                    status_code=404,
                    detail="Занятие не найдено",
                )

            # Проверяем статус занятия в соответствии с событием
            expected_status = (
                "CANCELLED"
                if event_type == "SCHEDULE_CANCELLED"
                else "PUBLISHED"
            )

            if str(row[1]) != expected_status:
                raise HTTPException(
                    status_code=409,
                    detail="Статус занятия не соответствует событию",
                )

            # Получаем студентов группы
            cursor.execute(
                """
                SELECT DISTINCT
                    u.email,
                    u.full_name
                FROM users u
                JOIN group_members gm ON gm.user_id = u.id
                WHERE u.is_active = TRUE
                  AND u.person_type = 'STUDENT'
                  AND u.role NOT IN ('ADMIN', 'TECH_ADMIN')
                  AND gm.group_id = (
                      SELECT group_id
                      FROM schedule_entries
                      WHERE id = %s
                  )
                """,
                (schedule_id,),
            )

            recipients = [
                {
                    "email": item[0],
                    "name": item[1],
                }
                for item in cursor.fetchall()
            ]

            # Получаем преподавателя
            cursor.execute(
                """
                SELECT
                    email,
                    full_name
                FROM users
                WHERE id = (
                    SELECT teacher_id
                    FROM schedule_entries
                    WHERE id = %s
                )
                  AND is_active = TRUE
                  AND person_type = 'EMPLOYEE'
                  AND role NOT IN ('ADMIN', 'TECH_ADMIN')
                """,
                (schedule_id,),
            )

            teacher = cursor.fetchone()

            # Добавляем преподавателя, если его еще нет в списке
            if teacher and all(
                item["email"] != teacher[0]
                for item in recipients
            ):
                recipients.append({
                    "email": teacher[0],
                    "name": teacher[1],
                })

    return {
        "scheduleId": str(row[0]),
        "startsAt": row[2].isoformat(),
        "endsAt": row[3].isoformat(),
        "subject": row[4],
        "group": row[5],
        "building": row[6],
        "room": row[7],
        "teacher": row[8],
        "recipients": recipients,
    }
