import psycopg
from app.core.config import database_config


def get_connection() -> psycopg.Connection:
    return psycopg.connect(**database_config())
