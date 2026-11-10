import os


def database_config() -> dict[str, str | int]:
    required = ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        raise RuntimeError("Missing required database environment variables")

    try:
        port = int(os.getenv("DB_PORT", "5432"))
    except ValueError as exc:
        raise RuntimeError("DB_PORT must be an integer") from exc

    if not 1 <= port <= 65535:
        raise RuntimeError("DB_PORT is outside the valid TCP port range")

    return {
        "host": os.environ["DB_HOST"],
        "port": port,
        "dbname": os.environ["DB_NAME"],
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
        "connect_timeout": 3,
        "application_name": "schedule-api",
    }


def session_ttl_hours() -> int:
    """Время жизни сессии в часах."""

    try:
        value = int(
            os.getenv("SESSION_TTL_HOURS", "12")
        )
    except ValueError as exc:
        raise RuntimeError(
            "SESSION_TTL_HOURS must be an integer"
        ) from exc

    if not 1 <= value <= 168:
        raise RuntimeError(
            "SESSION_TTL_HOURS must be between 1 and 168"
        )

    return value


def session_cookie_secure() -> bool:
    """Проверка настройки Secure для cookie."""

    value = os.getenv(
        "SESSION_COOKIE_SECURE", "true"
    ).strip().lower()

    if value not in {"true", "false"}:
        raise RuntimeError(
            "SESSION_COOKIE_SECURE must be true or false"
        )

    return value == "true"
