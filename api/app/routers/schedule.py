from collections import deque
from threading import Lock
from time import monotonic
from uuid import UUID, uuid4
import hashlib
import hmac
import json
import logging
from typing import Literal
from datetime import datetime, date, timedelta
from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    Cookie,
    Header
)
from pydantic import BaseModel, ConfigDict, Field
from psycopg.types.json import Jsonb
from psycopg.errors import UniqueViolation

from app.db.connection import get_connection
from app.dependencies.auth import get_current_user
from app.core.security import verify_csrf_token
from app.services.rabbitmq import publish_schedule_event

router = APIRouter(
    prefix="/api/schedule",
    tags=["schedule"]
)

logger = logging.getLogger(__name__)

# Ограничение частоты запросов
RATE_LIMIT = 60
RATE_WINDOW_SECONDS = 60

_request_times: dict[str, deque] = {}
_rate_lock = Lock()


def check_rate_limit(user_id: UUID):
    """Не более 60 запросов за 60 секунд для одного пользователя."""

    key = str(user_id)
    now = monotonic()

    with _rate_lock:

        if key not in _request_times:
            _request_times[key] = deque()

        requests = _request_times[key]

        # Удаляем запросы старше одной минуты
        while (
            requests
            and requests[0] <= now - RATE_WINDOW_SECONDS
        ):
            requests.popleft()

        # Проверяем ограничение
        if len(requests) >= RATE_LIMIT:
            raise HTTPException(
                status_code=429,
                detail="Слишком много запросов"
            )

        requests.append(now)


# Модель ответа
class ScheduleEntryResponse(BaseModel):
    model_config = ConfigDict(
        populate_by_name=True
    )

    id: UUID = Field(alias="Id")

    subject_id: UUID = Field(alias="subjectId")
    subject_name: str = Field(alias="subjectName")

    group_id: UUID = Field(alias="groupId")
    group_name: str = Field(alias="groupName")

    teacher_id: UUID | None = Field(alias="teacherId")
    teacher_name: str | None = Field(alias="teacherName")

    room_id: UUID = Field(alias="roomId")
    room_name: str = Field(alias="roomName")

    starts_at: datetime = Field(alias="startsAt")
    ends_at: datetime = Field(alias="endsAt")

    status: Literal[
        "draft",
        "published",
        "cancelled"
    ]


# Вспомогательная функция аудита
def write_schedule_audit(
    cursor,
    user_id: UUID,
    schedule_id: UUID,
    result: str,
    details: dict,
    action: str = "READ_SCHEDULE"
):
    cursor.execute(
        """
        INSERT INTO audit_events (
            actor_user_id,
            action,
            object_type,
            object_id,
            result,
            details
        )
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (
            user_id,
            action,
            "SCHEDULE_ENTRY",
            schedule_id,
            result,
            Jsonb(details)
        )
    )


# Вспомогательные справочники для административной веб-формы.
# Этот маршрут объявлен до /{schedule_id}, чтобы слово "options"
# не воспринималось как UUID занятия.
@router.get("/options")
def get_schedule_options(
    current_user: dict = Depends(get_current_user),
):
    if current_user["role"] != "ADMIN":
        raise HTTPException(
            status_code=403, detail="Операция доступна только ADMIN")

    check_rate_limit(current_user["id"])

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id, name FROM subjects ORDER BY name")
            subjects = [{"id": str(row[0]), "name": row[1]}
                        for row in cursor.fetchall()]

            cursor.execute("SELECT id, name FROM groups ORDER BY name")
            groups = [{"id": str(row[0]), "name": row[1]}
                      for row in cursor.fetchall()]

            cursor.execute(
                """SELECT id, CONCAT(building, ', ', room_number)
                   FROM rooms ORDER BY building, room_number"""
            )
            rooms = [{"id": str(row[0]), "name": row[1]}
                     for row in cursor.fetchall()]

            cursor.execute(
                """SELECT id, full_name FROM users
                   WHERE person_type = 'EMPLOYEE' AND is_active = TRUE
                   ORDER BY full_name"""
            )
            teachers = [{"id": str(row[0]), "fullName": row[1]}
                        for row in cursor.fetchall()]

            cursor.execute(
                """INSERT INTO audit_events (
                       actor_user_id, action, object_type, result, details
                   ) VALUES (%s, %s, %s, %s, %s)""",
                (
                    current_user["id"],
                    "READ_SCHEDULE_OPTIONS",
                    "SCHEDULE_LOOKUPS",
                    "SUCCESS",
                    Jsonb({
                        "subjects": len(subjects),
                        "groups": len(groups),
                        "rooms": len(rooms),
                        "teachers": len(teachers),
                    }),
                ),
            )

    return {
        "subjects": subjects,
        "groups": groups,
        "rooms": rooms,
        "teachers": teachers,
    }


# OP-03. GET /api/schedule/{id}
@router.get(
    "/{schedule_id}",
    response_model=ScheduleEntryResponse
)
def get_schedule_entry(
    schedule_id: UUID,
    current_user: dict = Depends(get_current_user)
):

    user_id = current_user["id"]
    role = current_user["role"]

    # Проверяем частоту запросов
    check_rate_limit(user_id)

    result = None

    with get_connection() as connection:
        with connection.cursor() as cursor:

            # Проверяем роль
            if role not in ("USER", "ADMIN"):

                write_schedule_audit(
                    cursor,
                    user_id,
                    schedule_id,
                    "DENIED",
                    {
                        "reason": "role_not_allowed"
                    }
                )

            else:

                # Формируем запрос в зависимости от роли
                if role == "ADMIN":

                    # Администратор может получить любую существующую запись

                    cursor.execute(
                        """
                        SELECT
                            se.id,
                            se.subject_id,
                            s.name,
                            se.group_id,
                            g.name,
                            se.teacher_id,
                            teacher.full_name,
                            se.room_id,
                            r.room_number,
                            se.starts_at,
                            se.ends_at,
                            se.status
                        FROM schedule_entries se
                        JOIN subjects s
                            ON s.id = se.subject_id
                        JOIN groups g
                            ON g.id = se.group_id
                        LEFT JOIN users teacher
                            ON teacher.id = se.teacher_id
                        JOIN rooms r
                            ON r.id = se.room_id
                        WHERE se.id = %s
                        """,
                        (schedule_id,)
                    )

                else:

                    # Обычный пользователь получает только опубликованные занятия своих учебных групп
                    cursor.execute(
                        """
                        SELECT
                            se.id,
                            se.subject_id,
                            s.name,
                            se.group_id,
                            g.name,
                            se.teacher_id,
                            teacher.full_name,
                            se.room_id,
                            r.room_number,
                            se.starts_at,
                            se.ends_at,
                            se.status
                        FROM schedule_entries se
                        JOIN subjects s
                            ON s.id = se.subject_id
                        JOIN groups g
                            ON g.id = se.group_id
                        LEFT JOIN users teacher
                            ON teacher.id = se.teacher_id
                        JOIN rooms r
                            ON r.id = se.room_id
                        WHERE se.id = %s
                          AND se.status = 'PUBLISHED'
                          AND EXISTS (
                              SELECT 1
                              FROM group_members gm
                              WHERE gm.group_id = se.group_id
                                AND gm.user_id = %s
                          )
                        """,
                        (schedule_id, user_id)
                    )

                # Получаем запись
                row = cursor.fetchone()

                if row is None:

                    # Объект отсутствует либо недоступен пользователю

                    write_schedule_audit(
                        cursor,
                        user_id,
                        schedule_id,
                        "DENIED",
                        {
                            "reason": "not_found_or_access_denied"
                        }
                    )

                else:

                    # Формируем ответ
                    result = {
                        "Id": row[0],

                        "subjectId": row[1],
                        "subjectName": row[2],

                        "groupId": row[3],
                        "groupName": row[4],

                        "teacherId": row[5],
                        "teacherName": row[6],

                        "roomId": row[7],
                        "roomName": row[8],

                        "startsAt": row[9],
                        "endsAt": row[10],

                        "status": str(row[11]).lower()
                    }

                    # Записываем успешную операцию
                    write_schedule_audit(
                        cursor,
                        user_id,
                        schedule_id,
                        "SUCCESS",
                        {
                            "group_id": str(row[3]),
                            "status": str(row[11])
                        }
                    )

    # Проверки выполняем после завершения транзакции, чтобы записи аудита не откатывались
    if role not in ("USER", "ADMIN"):
        raise HTTPException(
            status_code=404,
            detail="Занятие не найдено или недоступно"
        )

    if result is None:
        raise HTTPException(
            status_code=404,
            detail="Занятие не найдено или недоступно"
        )

    return result


class ScheduleListItem(BaseModel):
    id: UUID
    subjectName: str
    groupName: str
    teacherName: str | None
    roomName: str
    startsAt: datetime
    endsAt: datetime
    status: str


class ScheduleListResponse(BaseModel):
    items: list[ScheduleListItem]
    page: int
    size: int
    total: int


class ScheduleCreateRequest(BaseModel):
    model_config = ConfigDict(
        populate_by_name=True,
        extra="forbid"
    )

    subject_id: UUID = Field(alias="subjectId")
    group_id: UUID = Field(alias="groupId")
    teacher_id: UUID | None = Field(
        default=None,
        alias="teachedId"
    )
    room_id: UUID = Field(alias="roomId")

    starts_at: datetime = Field(alias="startsAt")
    ends_at: datetime = Field(alias="endsAt")


class ScheduleCreateResponse(BaseModel):
    id: UUID
    status: Literal["draft"]
    createdAt: datetime
    startsAt: datetime
    endsAt: datetime


def find_schedule_conflict(
    cursor,
    field_name: str,
    field_value: UUID,
    starts_at: datetime,
    ends_at: datetime,
    exclude_schedule_id: UUID | None = None
):
    """
    Ищет пересечение временных интервалов
    для группы, преподавателя или аудитории.

    CANCELLED-записи не учитываются.
    """

    # field_name используется только с фиксированными именами колонок из вызовов ниже
    exclude_sql = "AND id <> %s" if exclude_schedule_id is not None else ""
    params = [field_value, ends_at, starts_at]
    if exclude_schedule_id is not None:
        params.append(exclude_schedule_id)

    cursor.execute(
        f"""
        SELECT id
        FROM schedule_entries
        WHERE {field_name} = %s
          AND status <> 'CANCELLED'
          AND starts_at < %s
          AND ends_at > %s
          {exclude_sql}
        LIMIT 1
        """,
        tuple(params)
    )

    return cursor.fetchone()


# OP-04. GET /api/schedule
@router.get("", response_model=ScheduleListResponse)
def get_schedule(
    from_date: date = Query(alias="from"),
    to_date: date = Query(alias="to"),

    subject_id: UUID | None = Query(default=None, alias="subjectId"),
    group_id: UUID | None = Query(default=None, alias="groupId"),
    teacher_id: UUID | None = Query(default=None, alias="teachedId"),
    room_id: UUID | None = Query(default=None, alias="roomId"),

    page: int = Query(default=1, ge=1),
    size: int = Query(default=20, ge=1, le=100),

    current_user: dict = Depends(get_current_user)
):
    user_id = current_user["id"]
    role = current_user["role"]

    # Проверка периода
    if to_date < from_date:
        raise HTTPException(
            status_code=400,
            detail="Некорректный период"
        )

    if (to_date - from_date).days > 30:
        raise HTTPException(
            status_code=400,
            detail="Максимальный период — 31 день"
        )

    # Проверка административного фильтра
    if group_id is not None and role != "ADMIN":
        raise HTTPException(
            status_code=403,
            detail="Фильтр groupId доступен только ADMIN"
        )

    # Ограничение частоты
    check_rate_limit(user_id)

    # Формирование условий SQL
    conditions = [
        "se.starts_at >= %s",
        "se.starts_at < %s",
        "se.status <> 'CANCELLED'"
    ]

    params = [
        from_date,
        to_date + timedelta(days=1)
    ]

    if subject_id is not None:
        conditions.append("se.subject_id = %s")
        params.append(subject_id)

    if teacher_id is not None:
        conditions.append("se.teacher_id = %s")
        params.append(teacher_id)

    if room_id is not None:
        conditions.append("se.room_id = %s")
        params.append(room_id)

    # Ограничение доступа к группам
    if role == "USER":
        conditions.append("""
            EXISTS (
                SELECT 1
                FROM group_members gm
                WHERE gm.group_id = se.group_id
                  AND gm.user_id = %s
            )
        """)
        params.append(user_id)

    elif group_id is not None:
        conditions.append("se.group_id = %s")
        params.append(group_id)

    where_sql = " AND ".join(conditions)

    offset = (page - 1) * size

    items = []
    total = 0

    with get_connection() as connection:
        with connection.cursor() as cursor:

            # Получаем общее количество записей
            cursor.execute(
                f"""
                SELECT COUNT(*)
                FROM schedule_entries se
                WHERE {where_sql}
                """,
                tuple(params)
            )

            total = cursor.fetchone()[0]

            # Получаем страницу расписания
            cursor.execute(
                f"""
                SELECT
                    se.id,
                    s.name,
                    g.name,
                    teacher.full_name,
                    CONCAT(r.building, ', ', r.room_number),
                    se.starts_at,
                    se.ends_at,
                    se.status
                FROM schedule_entries se
                JOIN subjects s
                    ON s.id = se.subject_id
                JOIN groups g
                    ON g.id = se.group_id
                LEFT JOIN users teacher
                    ON teacher.id = se.teacher_id
                JOIN rooms r
                    ON r.id = se.room_id
                WHERE {where_sql}
                ORDER BY se.starts_at ASC
                LIMIT %s OFFSET %s
                """,
                tuple(params) + (size, offset)
            )

            rows = cursor.fetchall()

            items = [
                {
                    "id": row[0],
                    "subjectName": row[1],
                    "groupName": row[2],
                    "teacherName": row[3],
                    "roomName": row[4],
                    "startsAt": row[5],
                    "endsAt": row[6],
                    "status": str(row[7]).lower()
                }
                for row in rows
            ]

            # Аудит операции
            cursor.execute(
                """
                INSERT INTO audit_events (
                    actor_user_id,
                    action,
                    object_type,
                    result,
                    details
                )
                VALUES (%s, %s, %s, %s, %s)
                """,
                (
                    user_id,
                    "READ_SCHEDULE_LIST",
                    "SCHEDULE",
                    "SUCCESS",
                    Jsonb({
                        "from": from_date.isoformat(),
                        "to": to_date.isoformat(),
                        "subject_id": str(subject_id) if subject_id else None,
                        "group_id": str(group_id) if group_id else None,
                        "teacher_id": str(teacher_id) if teacher_id else None,
                        "room_id": str(room_id) if room_id else None,
                        "page": page,
                        "size": size,
                        "returned": len(items)
                    })
                )
            )

    # Возвращаем результат
    return {
        "items": items,
        "page": page,
        "size": size,
        "total": total
    }


# OP-05. POST /api/schedule
@router.post(
    "",
    response_model=ScheduleCreateResponse
)
@router.post(
    "/",
    response_model=ScheduleCreateResponse,
    include_in_schema=False,
)
def create_schedule_entry(
    payload: ScheduleCreateRequest,

    csrf_cookie: str | None = Cookie(
        default=None,
        alias="csrfToken"
    ),

    csrf_header: str | None = Header(
        default=None,
        alias="X-CSRF-Token"
    ),

    idempotency_key: str | None = Header(
        default=None,
        alias="Idempotency-Key"
    ),

    current_user: dict = Depends(get_current_user)
):
    user_id = current_user["id"]
    role = current_user["role"]
    session_id = current_user.get("session_id")

    # 1. Проверяем роль
    if role != "ADMIN":
        raise HTTPException(
            status_code=403,
            detail="Операция доступна только ADMIN"
        )

    # 2. Проверяем CSRF
    if (
        not session_id
        or not csrf_cookie
        or not csrf_header
        or not hmac.compare_digest(
            csrf_cookie,
            csrf_header
        )
        or not verify_csrf_token(
            session_id,
            csrf_header
        )
    ):
        raise HTTPException(
            status_code=403,
            detail="Недействительный CSRF-токен"
        )

    # 3. Проверяем Idempotency-Key
    if not idempotency_key:
        raise HTTPException(
            status_code=400,
            detail="Отсутствует Idempotency-Key"
        )

    try:
        idempotency_uuid = UUID(idempotency_key)
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="Некорректный Idempotency-Key"
        )

    # 4. Проверяем временной интервал
    if (
        payload.starts_at.tzinfo is None
        or payload.starts_at.utcoffset() is None
        or payload.ends_at.tzinfo is None
        or payload.ends_at.utcoffset() is None
    ):
        raise HTTPException(
            status_code=422,
            detail="Время должно содержать часовой пояс"
        )

    if payload.ends_at <= payload.starts_at:
        raise HTTPException(
            status_code=422,
            detail="Окончание занятия должно быть позже начала"
        )

    # 5. Ограничение частоты
    check_rate_limit(user_id)

    # 6. Формируем хеш запроса для идемпотентности
    request_data = payload.model_dump(
        mode="json",
        by_alias=True
    )

    request_hash = hashlib.sha256(
        json.dumps(
            request_data,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False
        ).encode("utf-8")
    ).digest()

    endpoint_name = "POST /api/schedule"

    response_data = None

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:

                # 7. Проверка Idempotency-Key

                # Удаляем истёкший ключ, если он есть.
                cursor.execute(
                    """
                    DELETE FROM idempotency_keys
                    WHERE owner_user_id = %s
                      AND key = %s
                      AND expires_at <= now()
                    """,
                    (
                        user_id,
                        idempotency_uuid
                    )
                )

                # Регистрируем новый ключ.
                cursor.execute(
                    """
                    INSERT INTO idempotency_keys (
                        owner_user_id,
                        key,
                        endpoint,
                        request_hash,
                        expires_at
                    )
                    VALUES (
                        %s,
                        %s,
                        %s,
                        %s,
                        now() + INTERVAL '24 hours'
                    )
                    ON CONFLICT (owner_user_id, key)
                    DO NOTHING
                    RETURNING key
                    """,
                    (
                        user_id,
                        idempotency_uuid,
                        endpoint_name,
                        request_hash
                    )
                )

                new_key = cursor.fetchone()

                # Если ключ уже существует,
                # проверяем исходный запрос.
                if new_key is None:

                    cursor.execute(
                        """
                        SELECT
                            endpoint,
                            request_hash,
                            response_status,
                            response_body
                        FROM idempotency_keys
                        WHERE owner_user_id = %s
                          AND key = %s
                        FOR UPDATE
                        """,
                        (
                            user_id,
                            idempotency_uuid
                        )
                    )

                    saved = cursor.fetchone()

                    if saved is None:
                        raise HTTPException(
                            status_code=409,
                            detail="Не удалось проверить Idempotency-Key"
                        )

                    saved_endpoint = saved[0]
                    saved_hash = bytes(saved[1])
                    saved_status = saved[2]
                    saved_body = saved[3]

                    # Тот же ключ нельзя использовать
                    # для другого endpoint или тела запроса.
                    if (
                        saved_endpoint != endpoint_name
                        or not hmac.compare_digest(
                            saved_hash,
                            request_hash
                        )
                    ):
                        raise HTTPException(
                            status_code=409,
                            detail=(
                                "Idempotency-Key уже использован "
                                "с другим запросом"
                            )
                        )

                    # Возвращаем ранее сохранённый ответ.
                    if saved_status is not None and saved_body is not None:
                        response_data = saved_body

                    else:
                        raise HTTPException(
                            status_code=409,
                            detail="Предыдущая операция ещё не завершена"
                        )

                else:

                    # 8. Проверка существования объектов

                    # Проверяем группу и блокируем её строку.
                    cursor.execute(
                        """
                        SELECT id
                        FROM groups
                        WHERE id = %s
                        FOR UPDATE
                        """,
                        (payload.group_id,)
                    )

                    if cursor.fetchone() is None:
                        raise HTTPException(
                            status_code=422,
                            detail="Учебная группа не найдена"
                        )

                    # Проверяем дисциплину.
                    cursor.execute(
                        """
                        SELECT id
                        FROM subjects
                        WHERE id = %s
                        FOR UPDATE
                        """,
                        (payload.subject_id,)
                    )

                    if cursor.fetchone() is None:
                        raise HTTPException(
                            status_code=422,
                            detail="Дисциплина не найдена"
                        )

                    # Проверяем преподавателя, если он указан.
                    if payload.teacher_id is not None:

                        cursor.execute(
                            """
                            SELECT id
                            FROM users
                            WHERE id = %s
                              AND person_type = 'EMPLOYEE'
                              AND is_active = TRUE
                            FOR UPDATE
                            """,
                            (payload.teacher_id,)
                        )

                        if cursor.fetchone() is None:
                            raise HTTPException(
                                status_code=422,
                                detail="Преподаватель не найден или неактивен"
                            )

                    # Проверяем аудиторию.
                    cursor.execute(
                        """
                        SELECT id
                        FROM rooms
                        WHERE id = %s
                        FOR UPDATE
                        """,
                        (payload.room_id,)
                    )

                    if cursor.fetchone() is None:
                        raise HTTPException(
                            status_code=422,
                            detail="Аудитория не найдена"
                        )

                    # 9. Проверка конфликтов расписания

                    conflict = find_schedule_conflict(
                        cursor,
                        "group_id",
                        payload.group_id,
                        payload.starts_at,
                        payload.ends_at
                    )

                    if conflict:
                        raise HTTPException(
                            status_code=409,
                            detail="В это время у группы уже есть занятие"
                        )

                    if payload.teacher_id is not None:

                        conflict = find_schedule_conflict(
                            cursor,
                            "teacher_id",
                            payload.teacher_id,
                            payload.starts_at,
                            payload.ends_at
                        )

                        if conflict:
                            raise HTTPException(
                                status_code=409,
                                detail=(
                                    "У преподавателя уже есть занятие "
                                    "в это время"
                                )
                            )

                    conflict = find_schedule_conflict(
                        cursor,
                        "room_id",
                        payload.room_id,
                        payload.starts_at,
                        payload.ends_at
                    )

                    if conflict:
                        raise HTTPException(
                            status_code=409,
                            detail="Аудитория уже занята в это время"
                        )

                    # 10. Создание занятия

                    schedule_id = uuid4()

                    cursor.execute(
                        """
                        INSERT INTO schedule_entries (
                            id,
                            group_id,
                            subject_id,
                            teacher_id,
                            room_id,
                            created_by_user_id,
                            starts_at,
                            ends_at,
                            status
                        )
                        VALUES (
                            %s, %s, %s, %s, %s,
                            %s, %s, %s, 'DRAFT'
                        )
                        RETURNING
                            id,
                            created_at,
                            starts_at,
                            ends_at
                        """,
                        (
                            schedule_id,
                            payload.group_id,
                            payload.subject_id,
                            payload.teacher_id,
                            payload.room_id,
                            user_id,
                            payload.starts_at,
                            payload.ends_at
                        )
                    )

                    row = cursor.fetchone()

                    # 11. Формирование ответа

                    response_data = {
                        "id": row[0],
                        "status": "draft",
                        "createdAt": row[1],
                        "startsAt": row[2],
                        "endsAt": row[3]
                    }

                    # 12. Запись аудита

                    write_schedule_audit(
                        cursor,
                        user_id,
                        schedule_id,
                        "SUCCESS",
                        {
                            "group_id": str(payload.group_id),
                            "subject_id": str(payload.subject_id),
                            "teacher_id": (
                                str(payload.teacher_id)
                                if payload.teacher_id
                                else None
                            ),
                            "room_id": str(payload.room_id),
                            "starts_at": payload.starts_at.isoformat(),
                            "ends_at": payload.ends_at.isoformat(),
                            "status": "DRAFT"
                        },
                        action="CREATE_SCHEDULE"
                    )

                    # 13. Сохраняем ответ для повторного
                    #     запроса с тем же ключом

                    cursor.execute(
                        """
                        UPDATE idempotency_keys
                        SET
                            response_status = 200,
                            response_body = %s
                        WHERE owner_user_id = %s
                          AND key = %s
                        """,
                        (
                            Jsonb({
                                "id": str(response_data["id"]),
                                "status": response_data["status"],
                                "createdAt": response_data["createdAt"].isoformat(),
                                "startsAt": response_data["startsAt"].isoformat(),
                                "endsAt": response_data["endsAt"].isoformat()
                            }),
                            user_id,
                            idempotency_uuid
                        )
                    )

        return response_data

    except UniqueViolation:
        raise HTTPException(
            status_code=409,
            detail="Обнаружен конфликт расписания"
        )


# OP-06. PATCH /api/schedule/{id}
class SchedulePatchRequest(BaseModel):
    """Разрешенные поля частичного изменения занятия."""

    model_config = ConfigDict(populate_by_name=True, extra="forbid")

    subject_id: UUID | None = Field(default=None, alias="subjectId")
    teacher_id: UUID | None = Field(default=None, alias="teachedId")
    room_id: UUID | None = Field(default=None, alias="roomId")
    starts_at: datetime | None = Field(default=None, alias="startsAt")
    ends_at: datetime | None = Field(default=None, alias="endsAt")
    status: Literal["draft", "published", "cancelled"] | None = None


class SchedulePatchResponse(BaseModel):
    id: UUID
    subjectId: UUID
    groupId: UUID
    teachedId: UUID | None
    roomId: UUID
    startsAt: datetime
    endsAt: datetime
    status: Literal["draft", "published", "cancelled"]
    updatedAt: datetime


@router.patch("/{schedule_id}", response_model=SchedulePatchResponse)
def update_schedule_entry(
    schedule_id: UUID,
    payload: SchedulePatchRequest,
    csrf_cookie: str | None = Cookie(default=None, alias="csrfToken"),
    csrf_header: str | None = Header(default=None, alias="X-CSRF-Token"),
    current_user: dict = Depends(get_current_user),
):
    user_id = current_user["id"]

    # Проверка роли администратора
    if current_user["role"] != "ADMIN":
        raise HTTPException(
            status_code=403, detail="Операция доступна только ADMIN")

    # Проверка CSRF: cookie должна совпасть с заголовком,
    #    а подпись должна быть связана с текущей серверной сессией
    if (
        not csrf_cookie
        or not csrf_header
        or not hmac.compare_digest(csrf_cookie, csrf_header)
        or not verify_csrf_token(current_user["session_id"], csrf_header)
    ):
        raise HTTPException(
            status_code=403, detail="Недействительный CSRF-токен")

    # PATCH без полей не имеет смысла
    provided_fields = payload.model_fields_set
    if not provided_fields:
        raise HTTPException(
            status_code=400, detail="Тело PATCH не содержит изменений")

    nullable_forbidden = {"subject_id", "room_id",
                          "starts_at", "ends_at", "status"}
    if any(getattr(payload, field) is None for field in nullable_forbidden & provided_fields):
        raise HTTPException(
            status_code=422, detail="Поле не может иметь значение null")

    if "starts_at" in provided_fields and payload.starts_at is not None:
        if payload.starts_at.tzinfo is None or payload.starts_at.utcoffset() is None:
            raise HTTPException(
                status_code=422, detail="Время должно содержать часовой пояс")
    if "ends_at" in provided_fields and payload.ends_at is not None:
        if payload.ends_at.tzinfo is None or payload.ends_at.utcoffset() is None:
            raise HTTPException(
                status_code=422, detail="Время должно содержать часовой пояс")

    # Ограничение частоты запросов
    check_rate_limit(user_id)

    response_data = None
    notification_event = None

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                # Блокируем изменяемую запись, чтобы переход состояния и
                # проверка конфликтов выполнялись относительно актуальной версии
                cursor.execute(
                    """
                    SELECT group_id, subject_id, teacher_id, room_id,
                           starts_at, ends_at, status, updated_at
                    FROM schedule_entries
                    WHERE id = %s
                    FOR UPDATE
                    """,
                    (schedule_id,),
                )
                current = cursor.fetchone()
                if current is None:
                    raise HTTPException(
                        status_code=404, detail="Занятие не найдено")

                (
                    old_group_id, old_subject_id, old_teacher_id, old_room_id,
                    old_start, old_end, old_status_db, old_updated_at,
                ) = current
                old_status = str(old_status_db)

                new_subject_id = payload.subject_id if "subject_id" in provided_fields else old_subject_id
                new_teacher_id = payload.teacher_id if "teacher_id" in provided_fields else old_teacher_id
                new_room_id = payload.room_id if "room_id" in provided_fields else old_room_id
                new_start = payload.starts_at if "starts_at" in provided_fields else old_start
                new_end = payload.ends_at if "ends_at" in provided_fields else old_end
                new_status = payload.status.upper() if "status" in provided_fields else old_status

                if new_end <= new_start:
                    raise HTTPException(
                        status_code=422, detail="Окончание занятия должно быть позже начала")

                # Допустимые переходы. Публикация выполняется только OP-07;
                # отмененную запись нельзя вернуть в активное расписание
                allowed_transitions = {
                    "DRAFT": {"DRAFT", "CANCELLED"},
                    "PUBLISHED": {"PUBLISHED", "CANCELLED"},
                    "CANCELLED": {"CANCELLED"},
                }
                if new_status not in allowed_transitions.get(old_status, set()):
                    raise HTTPException(
                        status_code=409,
                        detail="Недопустимый переход состояния; для публикации используйте OP-07",
                    )

                # Проверка существования связанных объектов. Блокировки
                #    ресурсов согласованы с порядком OP-05: группа, дисциплина,
                #    преподаватель, аудитория
                cursor.execute(
                    "SELECT id FROM groups WHERE id = %s FOR UPDATE", (old_group_id,))
                if cursor.fetchone() is None:
                    raise HTTPException(
                        status_code=422, detail="Учебная группа не найдена")

                cursor.execute(
                    "SELECT id FROM subjects WHERE id = %s FOR UPDATE", (new_subject_id,))
                if cursor.fetchone() is None:
                    raise HTTPException(
                        status_code=422, detail="Дисциплина не найдена")

                if new_teacher_id is not None:
                    cursor.execute(
                        """SELECT id FROM users
                           WHERE id = %s AND person_type = 'EMPLOYEE' AND is_active = TRUE
                           FOR UPDATE""",
                        (new_teacher_id,),
                    )
                    if cursor.fetchone() is None:
                        raise HTTPException(
                            status_code=422, detail="Преподаватель не найден или неактивен")

                cursor.execute(
                    "SELECT id FROM rooms WHERE id = %s FOR UPDATE", (new_room_id,))
                if cursor.fetchone() is None:
                    raise HTTPException(
                        status_code=422, detail="Аудитория не найдена")

                # Проверяем пересечения, если запись остается активной и
                #    меняются параметры, влияющие на занятость ресурсов
                scheduling_changed = (
                    new_teacher_id != old_teacher_id
                    or new_room_id != old_room_id
                    or new_start != old_start
                    or new_end != old_end
                )
                if new_status != "CANCELLED" and scheduling_changed:
                    conflicts = (
                        ("group_id", old_group_id,
                         "В это время у группы уже есть занятие"),
                        ("teacher_id", new_teacher_id,
                         "У преподавателя уже есть занятие в это время"),
                        ("room_id", new_room_id, "Аудитория уже занята в это время"),
                    )
                    for field_name, field_value, message in conflicts:
                        if field_value is None:
                            continue
                        if find_schedule_conflict(
                            cursor, field_name, field_value, new_start, new_end,
                            exclude_schedule_id=schedule_id,
                        ):
                            raise HTTPException(
                                status_code=409, detail=message)

                # Не обновляем updated_at при повторном PATCH с теми же
                #    значениями. Так назначающее изменение остается идемпотентным
                has_changes = any((
                    new_subject_id != old_subject_id,
                    new_teacher_id != old_teacher_id,
                    new_room_id != old_room_id,
                    new_start != old_start,
                    new_end != old_end,
                    new_status != old_status,
                ))

                if has_changes:
                    cursor.execute(
                        """
                        UPDATE schedule_entries
                        SET subject_id = %s,
                            teacher_id = %s,
                            room_id = %s,
                            starts_at = %s,
                            ends_at = %s,
                            status = %s,
                            updated_at = now()
                        WHERE id = %s
                        RETURNING id, subject_id, group_id, teacher_id, room_id,
                                  starts_at, ends_at, status, updated_at
                        """,
                        (
                            new_subject_id, new_teacher_id, new_room_id,
                            new_start, new_end, new_status, schedule_id,
                        ),
                    )
                    row = cursor.fetchone()

                    if old_status == "PUBLISHED" and new_status == "PUBLISHED":
                        notification_event = "SCHEDULE_UPDATED"
                    elif old_status == "PUBLISHED" and new_status == "CANCELLED":
                        notification_event = "SCHEDULE_CANCELLED"

                    # Аудитируем старые и новые значения только при изменении
                    write_schedule_audit(
                        cursor,
                        user_id,
                        schedule_id,
                        "SUCCESS",
                        {
                            "old": {
                                "subject_id": str(old_subject_id),
                                "group_id": str(old_group_id),
                                "teacher_id": str(old_teacher_id) if old_teacher_id else None,
                                "room_id": str(old_room_id),
                                "starts_at": old_start.isoformat(),
                                "ends_at": old_end.isoformat(),
                                "status": old_status,
                            },
                            "new": {
                                "subject_id": str(row[1]),
                                "group_id": str(row[2]),
                                "teacher_id": str(row[3]) if row[3] else None,
                                "room_id": str(row[4]),
                                "starts_at": row[5].isoformat(),
                                "ends_at": row[6].isoformat(),
                                "status": str(row[7]),
                            },
                        },
                        action="UPDATE_SCHEDULE",
                    )
                else:
                    row = (
                        schedule_id, old_subject_id, old_group_id, old_teacher_id,
                        old_room_id, old_start, old_end, old_status_db, old_updated_at,
                    )

                response_data = {
                    "id": row[0],
                    "subjectId": row[1],
                    "groupId": row[2],
                    "teachedId": row[3],
                    "roomId": row[4],
                    "startsAt": row[5],
                    "endsAt": row[6],
                    "status": str(row[7]).lower(),
                    "updatedAt": row[8],
                }

        # К этому моменту транзакция PostgreSQL уже завершена
        if notification_event:
            try:
                publish_schedule_event(
                    notification_event,
                    str(schedule_id),
                )
            except Exception:
                # Изменение расписания уже сохранено
                # Ошибку доставки фиксируем в журнале API
                logger.exception(
                    "Не удалось отправить событие %s для занятия %s",
                    notification_event,
                    schedule_id,
                )

        return response_data
    except UniqueViolation:
        raise HTTPException(
            status_code=409, detail="Обнаружен конфликт расписания") from None


# OP-07. POST /api/schedule/{id}/publish
class SchedulePublishResponse(BaseModel):
    id: UUID
    status: Literal["published"]
    publishedAt: datetime


@router.post("/{schedule_id}/publish", response_model=SchedulePublishResponse)
def publish_schedule_entry(
    schedule_id: UUID,
    csrf_cookie: str | None = Cookie(default=None, alias="csrfToken"),
    csrf_header: str | None = Header(default=None, alias="X-CSRF-Token"),
    idempotency_key: str | None = Header(
        default=None, alias="Idempotency-Key"),
    current_user: dict = Depends(get_current_user),
):
    user_id = current_user["id"]

    # Только ADMIN может публиковать записи
    if current_user["role"] != "ADMIN":
        raise HTTPException(
            status_code=403, detail="Операция доступна только ADMIN")

    # CSRF-проверка для cookie-аутентификации
    if (
        not csrf_cookie
        or not csrf_header
        or not hmac.compare_digest(csrf_cookie, csrf_header)
        or not verify_csrf_token(current_user["session_id"], csrf_header)
    ):
        raise HTTPException(
            status_code=403, detail="Недействительный CSRF-токен")

    # Проверка UUID ключа идемпотентности
    if not idempotency_key:
        raise HTTPException(
            status_code=400, detail="Отсутствует Idempotency-Key")
    try:
        idempotency_uuid = UUID(idempotency_key)
    except ValueError:
        raise HTTPException(
            status_code=400, detail="Некорректный Idempotency-Key") from None

    check_rate_limit(user_id)
    endpoint_name = "POST /api/schedule/{id}/publish"
    request_hash = hashlib.sha256(
        f"{endpoint_name}:{schedule_id}".encode("utf-8")).digest()
    response_data = None
    notification_event = None

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                # Регистрируем ключ; повтор с тем же ключом вернет первый ответ
                cursor.execute(
                    """DELETE FROM idempotency_keys
                       WHERE owner_user_id = %s AND key = %s AND expires_at <= now()""",
                    (user_id, idempotency_uuid),
                )
                cursor.execute(
                    """INSERT INTO idempotency_keys
                           (owner_user_id, key, endpoint, request_hash, expires_at)
                       VALUES (%s, %s, %s, %s, now() + INTERVAL '24 hours')
                       ON CONFLICT (owner_user_id, key) DO NOTHING
                       RETURNING key""",
                    (user_id, idempotency_uuid, endpoint_name, request_hash),
                )
                is_new_key = cursor.fetchone() is not None

                if not is_new_key:
                    cursor.execute(
                        """SELECT endpoint, request_hash, response_status, response_body
                           FROM idempotency_keys
                           WHERE owner_user_id = %s AND key = %s
                           FOR UPDATE""",
                        (user_id, idempotency_uuid),
                    )
                    saved = cursor.fetchone()
                    if saved is None:
                        raise HTTPException(
                            status_code=409, detail="Не удалось проверить Idempotency-Key")
                    if saved[0] != endpoint_name or not hmac.compare_digest(bytes(saved[1]), request_hash):
                        raise HTTPException(
                            status_code=409, detail="Idempotency-Key уже использован с другим запросом")
                    if saved[2] != 200 or saved[3] is None:
                        raise HTTPException(
                            status_code=409, detail="Предыдущая операция ещё не завершена")
                    response_data = saved[3]
                else:
                    # Блокируем занятие и проверяем допустимость перехода DRAFT -> PUBLISHED
                    cursor.execute(
                        """SELECT group_id, teacher_id, room_id, starts_at, ends_at, status
                           FROM schedule_entries WHERE id = %s FOR UPDATE""",
                        (schedule_id,),
                    )
                    entry = cursor.fetchone()
                    if entry is None:
                        raise HTTPException(
                            status_code=404, detail="Занятие не найдено")
                    group_id, teacher_id, room_id, starts_at, ends_at, status_db = entry
                    if str(status_db) != "DRAFT":
                        raise HTTPException(
                            status_code=409, detail="Опубликовать можно только занятие в статусе draft")

                    # Блокируем те же ресурсные строки, что и OP-05/OP-06,
                    #    чтобы параллельное создание или изменение не прошло
                    #    проверку занятости одновременно с публикацией
                    cursor.execute(
                        "SELECT id FROM groups WHERE id = %s FOR UPDATE", (group_id,))
                    if teacher_id is not None:
                        cursor.execute(
                            "SELECT id FROM users WHERE id = %s FOR UPDATE", (teacher_id,))
                    cursor.execute(
                        "SELECT id FROM rooms WHERE id = %s FOR UPDATE", (room_id,))

                    # Проверяем, что после создания не появился конфликт
                    for field_name, field_value, message in (
                        ("group_id", group_id, "В это время у группы уже есть занятие"),
                        ("teacher_id", teacher_id,
                         "У преподавателя уже есть занятие в это время"),
                        ("room_id", room_id, "Аудитория уже занята в это время"),
                    ):
                        if field_value is not None and find_schedule_conflict(
                            cursor, field_name, field_value, starts_at, ends_at,
                            exclude_schedule_id=schedule_id,
                        ):
                            raise HTTPException(
                                status_code=409, detail=message)

                    # Публикуем запись и сохраняем момент публикации
                    cursor.execute(
                        """UPDATE schedule_entries
                           SET status = 'PUBLISHED', published_at = now(), updated_at = now()
                           WHERE id = %s
                           RETURNING id, status, published_at""",
                        (schedule_id,),
                    )
                    row = cursor.fetchone()
                    response_data = {
                        "id": row[0],
                        "status": "published",
                        "publishedAt": row[2],
                    }

                    notification_event = "SCHEDULE_PUBLISHED"

                    write_schedule_audit(
                        cursor,
                        user_id,
                        schedule_id,
                        "SUCCESS",
                        {"old_status": "DRAFT", "new_status": "PUBLISHED",
                            "published_at": row[2].isoformat()},
                        action="PUBLISH_SCHEDULE",
                    )

                    # Фиксируем исходный ответ для повторной отправки
                    cursor.execute(
                        """UPDATE idempotency_keys
                           SET response_status = 200, response_body = %s
                           WHERE owner_user_id = %s AND key = %s""",
                        (
                            Jsonb(
                                {"id": str(row[0]), "status": "published", "publishedAt": row[2].isoformat()}),
                            user_id,
                            idempotency_uuid,
                        ),
                    )

        if notification_event:
            try:
                publish_schedule_event(
                    notification_event,
                    str(schedule_id),
                )
            except Exception:
                logger.exception(
                    "Не удалось отправить событие публикации занятия %s",
                    schedule_id,
                )

        return response_data
    except UniqueViolation:
        raise HTTPException(
            status_code=409, detail="Обнаружен конфликт расписания") from None


# OP-08. POST /api/schedule/ai-query. LLM-интеграция возвращает 501
@router.post("/ai-query", status_code=501)
def ai_query_not_implemented(
    current_user: dict = Depends(get_current_user),
):
    if current_user["role"] not in ("USER", "ADMIN"):
        raise HTTPException(
            status_code=403, detail="Операция недоступна для этой роли")
    raise HTTPException(
        status_code=501, detail="AI-поиск не реализуется в рамках ЛР-3")
