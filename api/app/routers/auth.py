from datetime import datetime, timedelta, timezone
import hashlib
import secrets
import uuid

from fastapi import APIRouter, HTTPException, Response
from fastapi import Depends, Header, Cookie
from pydantic import BaseModel, ConfigDict, Field
from psycopg.types.json import Jsonb

from app.core.config import (
    session_ttl_hours,
    session_cookie_secure
)
from app.core.security import (
    verify_password,
    create_csrf_token
)
from app.db.connection import get_connection
from app.dependencies.auth import get_current_user
from app.core.security import verify_csrf_token


router = APIRouter(
    prefix="/api/auth",
    tags=["auth"]
)


class LoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    login: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=1024)


class LoginResponse(BaseModel):
    status: str


# OP-01
@router.post(
    "/login",
    response_model=LoginResponse
)
def login(
    payload: LoginRequest,
    response: Response
) -> LoginResponse:

    authenticated = False
    raw_session_id = None

    ttl_seconds = session_ttl_hours() * 3600
    secure_cookie = session_cookie_secure()

    with get_connection() as connection:
        with connection.cursor() as cursor:

            # Ищем активного пользователя
            cursor.execute(
                """
                SELECT id, password_hash, password_salt
                FROM users
                WHERE login = %s
                  AND is_active = TRUE
                """,
                (payload.login,)
            )

            user = cursor.fetchone()

            # Проверяем пароль
            if user is not None:
                user_id, password_hash, password_salt = user

                authenticated = verify_password(
                    payload.password,
                    password_salt,
                    password_hash
                )

            else:
                user_id = None

            # Неверные учетные данные
            if not authenticated:

                cursor.execute(
                    """
                    INSERT INTO audit_events
                        (
                            actor_service,
                            action,
                            object_type,
                            result,
                            details
                        )
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (
                        "schedule-api",
                        "LOGIN",
                        "AUTHENTICATION",
                        "FAILURE",
                        Jsonb({
                            "reason": "invalid_credentials"
                        })
                    )
                )

            else:

                # Генерируем случайную сессию
                now = datetime.now(timezone.utc)

                expires_at = now + timedelta(
                    seconds=ttl_seconds
                )

                raw_session_id = secrets.token_urlsafe(32)

                # В БД сохраняем только SHA-256
                token_hash = hashlib.sha256(
                    raw_session_id.encode("ascii")
                ).digest()

                session_id = uuid.uuid4()

                # Сохраняем серверную сессию
                cursor.execute(
                    """
                    INSERT INTO sessions
                        (
                            id,
                            user_id,
                            token_hash,
                            created_at,
                            last_seen_at,
                            expires_at
                        )
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (
                        session_id,
                        user_id,
                        token_hash,
                        now,
                        now,
                        expires_at
                    )
                )

                # Записываем успешную авторизацию
                cursor.execute(
                    """
                    INSERT INTO audit_events
                        (
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
                        "LOGIN",
                        "SESSION",
                        session_id,
                        "SUCCESS",
                        Jsonb({
                            "method": "password"
                        })
                    )
                )

    # HTTP-ошибку выбрасываем после завершения транзакции, чтобы аудит ошибки сохранился
    if not authenticated or raw_session_id is None:
        raise HTTPException(
            status_code=401,
            detail="Неверный логин или пароль"
        )

    # Передаем идентификатор сессии клиенту
    response.set_cookie(
        key="sessionId",
        value=raw_session_id,
        max_age=ttl_seconds,
        httponly=True,
        secure=secure_cookie,
        samesite="lax",
        path="/"
    )

    csrf_token = create_csrf_token(session_id)

    response.set_cookie(
        key="csrfToken",
        value=csrf_token,
        max_age=ttl_seconds,
        httponly=False,
        secure=secure_cookie,
        samesite="lax",
        path="/"
    )

    return LoginResponse(status="ok")


# OP-02
@router.post("/logout")
def logout(
    response: Response,

    csrf_header: str | None = Header(
        default=None,
        alias="X-CSRF-Token"
    ),

    csrf_cookie: str | None = Cookie(
        default=None,
        alias="csrfToken"
    ),

    current_user: dict = Depends(get_current_user)
):

    # Проверяем наличие обоих вариантов токена
    if not csrf_header or not csrf_cookie:
        raise HTTPException(
            status_code=403,
            detail="CSRF-проверка не пройдена"
        )

    # Проверяем совпадение cookie и заголовка
    if not secrets.compare_digest(
        csrf_header,
        csrf_cookie
    ):
        raise HTTPException(
            status_code=403,
            detail="CSRF-проверка не пройдена"
        )

    # Проверяем криптографическую подпись
    if not verify_csrf_token(
        current_user["session_id"],
        csrf_header
    ):
        raise HTTPException(
            status_code=403,
            detail="CSRF-проверка не пройдена"
        )

    # Отзываем текущую сессию
    with get_connection() as connection:
        with connection.cursor() as cursor:

            cursor.execute(
                """
                UPDATE sessions
                SET revoked_at = now()
                WHERE id = %s
                  AND user_id = %s
                  AND revoked_at IS NULL
                RETURNING id
                """,
                (
                    current_user["session_id"],
                    current_user["id"]
                )
            )

            revoked_session = cursor.fetchone()

            if revoked_session is None:
                raise HTTPException(
                    status_code=401,
                    detail="Требуется авторизация"
                )

            # Аудит выхода
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
                    current_user["id"],
                    "LOGOUT",
                    "SESSION",
                    current_user["session_id"],
                    "SUCCESS",
                    Jsonb({
                        "reason": "user_logout"
                    })
                )
            )

    # Удаляем cookie клиента
    secure_cookie = session_cookie_secure()

    response.delete_cookie(
        key="sessionId",
        path="/",
        httponly=True,
        secure=secure_cookie,
        samesite="lax"
    )

    response.delete_cookie(
        key="csrfToken",
        path="/",
        httponly=False,
        secure=secure_cookie,
        samesite="lax"
    )

    return {
        "status": "ok"
    }

# Возвращает профиль пользователя для отображения веб-интерфейса
@router.get("/me")
def get_current_user_profile(
    current_user: dict = Depends(get_current_user),
):
    return {
        "id": str(current_user["id"]),
        "login": current_user["login"],
        "fullName": current_user["full_name"],
        "role": current_user["role"],
    }