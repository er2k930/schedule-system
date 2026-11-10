import logging
import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.db.connection import get_connection
from app.routers.auth import router as auth_router
from app.routers.schedule import router as schedule_router
from app.routers.jobs import router as jobs_router
from app.routers.internal import router as internal_router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("schedule-api")

app = FastAPI(
    title="Schedule API",
    version="0.1.0",
    description="API системы расписания",
)
app.include_router(auth_router)
app.include_router(schedule_router)
app.include_router(jobs_router)
app.include_router(internal_router)

@app.get("/health", tags=["health"], summary="Проверка API и подключения к БД")
def health() -> dict[str, str]:
    """Return success only when the API can execute a query in PostgreSQL."""
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
    except (psycopg.Error, RuntimeError):
        logger.exception("Database health check failed")
        raise HTTPException(
            status_code=503,
            detail="Service temporarily unavailable",
        ) from None
    except Exception:
        logger.exception("Unexpected health check failure")
        raise HTTPException(
            status_code=503,
            detail="Service temporarily unavailable",
        ) from None

    return {"status": "ok", "database": "ok"}


@app.exception_handler(RequestValidationError)
async def request_validation_error_handler(
    request: Request,
    exc: RequestValidationError,
):
    """Malformed request format maps to the 400 code in the API contracts."""
    return JSONResponse(
        status_code=400,
        content={"detail": "Некорректный формат запроса"},
    )


@app.exception_handler(Exception)
async def unexpected_error_handler(
    request: Request,
    exc: Exception
):
    logger.error(
        "Unhandled API error: %s",
        type(exc).__name__,
        exc_info=(type(exc), exc, exc.__traceback__)
    )
    return JSONResponse(
        status_code=500,
        content={
            "detail": "Внутренняя ошибка сервера"
        }
    )
