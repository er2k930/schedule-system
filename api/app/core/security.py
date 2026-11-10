import hashlib
import hmac
import os
import secrets

from argon2.low_level import Type, hash_secret_raw

ARGON2_TIME_COST = 3
ARGON2_MEMORY_COST_KIB = 65536
ARGON2_PARALLELISM = 1
ARGON2_HASH_LENGTH = 32


def verify_password(
    password: str,
    salt: bytes,
    stored_hash_hex: str
) -> bool:

    try:
        expected_hash = bytes.fromhex(stored_hash_hex)
    except (TypeError, ValueError):
        return False

    actual_hash = hash_secret_raw(
        secret=password.encode("utf-8"),
        salt=bytes(salt),
        time_cost=ARGON2_TIME_COST,
        memory_cost=ARGON2_MEMORY_COST_KIB,
        parallelism=ARGON2_PARALLELISM,
        hash_len=ARGON2_HASH_LENGTH,
        type=Type.ID,
    )

    return hmac.compare_digest(
        actual_hash,
        expected_hash
    )


def get_csrf_secret() -> bytes:
    """Получение секретного ключа CSRF."""

    secret = os.getenv("CSRF_SECRET", "")

    if len(secret.encode("utf-8")) < 32:
        raise RuntimeError(
            "CSRF_SECRET must contain at least 32 bytes"
        )

    return secret.encode("utf-8")


def create_csrf_token(session_id) -> str:
    """Создание подписанного CSRF-токена, связанного с конкретной сессией."""

    nonce = secrets.token_urlsafe(32)

    message = f"{session_id}:{nonce}".encode("utf-8")

    signature = hmac.new(
        get_csrf_secret(),
        message,
        hashlib.sha256
    ).hexdigest()

    return f"{nonce}.{signature}"


def verify_csrf_token(
    session_id,
    token: str
) -> bool:
    """Проверка подписи CSRF-токена."""

    if not token or len(token) > 512:
        return False

    try:
        nonce, signature = token.rsplit(".", 1)
    except ValueError:
        return False

    message = f"{session_id}:{nonce}".encode("utf-8")

    expected_signature = hmac.new(
        get_csrf_secret(),
        message,
        hashlib.sha256
    ).hexdigest()

    return hmac.compare_digest(
        signature,
        expected_signature
    )
