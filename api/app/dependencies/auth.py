import hashlib

from fastapi import Cookie, HTTPException

from app.db.connection import get_connection


def get_current_user(
    session_id: str | None = Cookie(
        default=None,
        alias="sessionId"
    )
) -> dict:
    """
    Проверяет серверную сессию и возвращает
    информацию о текущем пользователе.

    Проверяются:
    - наличие идентификатора сессии;
    - наличие сессии в БД;
    - срок действия;
    - отсутствие отзыва;
    - активность пользователя.
    """

    # Проверяем наличие cookie
    if not session_id or len(session_id) > 256:
        raise HTTPException(
            status_code=401,
            detail="Требуется авторизация"
        )

    # Получаем хеш идентификатора сессии
    token_hash = hashlib.sha256(
        session_id.encode("utf-8")
    ).digest()

    user = None

    with get_connection() as connection:
        with connection.cursor() as cursor:

            # Ищем действительную сессию
            cursor.execute(
                """
                SELECT
                    s.id,
                    u.id,
                    u.login,
                    u.full_name,
                    u.role
                FROM sessions s
                JOIN users u ON u.id = s.user_id
                WHERE s.token_hash = %s
                  AND s.revoked_at IS NULL
                  AND s.expires_at > now()
                  AND u.is_active = TRUE
                """,
                (token_hash,)
            )

            user = cursor.fetchone()

            if user is not None:

                # Обновляем время последней активности
                cursor.execute(
                    """
                    UPDATE sessions
                    SET last_seen_at = now()
                    WHERE id = %s
                    """,
                    (user[0],)
                )

    # Если сессия не найдена - 401
    if user is None:
        raise HTTPException(
            status_code=401,
            detail="Требуется авторизация"
        )

    # Возвращаем данные пользователя
    return {
        "session_id": user[0],
        "id": user[1],
        "login": user[2],
        "full_name": user[3],
        "role": str(user[4])
    }
