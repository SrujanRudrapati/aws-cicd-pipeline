"""Visit-counter storage backends.

The in-memory backend is used for local runs and CI. The Postgres backend is
used whenever DB_HOST is set: RDS in AWS, or the `db` service in docker compose.
"""

from __future__ import annotations

import json
import logging
import threading
from typing import Protocol

from .config import Config

log = logging.getLogger(__name__)


class Store(Protocol):
    backend: str

    def ping(self) -> bool: ...

    def get_visits(self) -> int: ...

    def increment_visits(self) -> int: ...


class InMemoryStore:
    """Per-process counter. With several gunicorn workers each has its own count."""

    backend = "memory"

    def __init__(self) -> None:
        self._count = 0
        self._lock = threading.Lock()

    def ping(self) -> bool:
        return True

    def get_visits(self) -> int:
        with self._lock:
            return self._count

    def increment_visits(self) -> int:
        with self._lock:
            self._count += 1
            return self._count


def resolve_db_credentials(config: Config) -> tuple[str, str]:
    """Explicit credentials win (local compose); otherwise read the RDS-managed secret."""
    if config.db_user and config.db_password:
        return config.db_user, config.db_password
    if config.db_secret_arn:
        import boto3

        client = boto3.client("secretsmanager", region_name=config.aws_region)
        payload = client.get_secret_value(SecretId=config.db_secret_arn)["SecretString"]
        secret = json.loads(payload)
        return secret["username"], secret["password"]
    raise RuntimeError(
        "DB_HOST is set but neither DB_USER/DB_PASSWORD nor DB_SECRET_ARN is configured"
    )


class PostgresStore:
    backend = "postgres"

    def __init__(self, config: Config) -> None:
        from psycopg.conninfo import make_conninfo
        from psycopg_pool import ConnectionPool

        user, password = resolve_db_credentials(config)
        conninfo = make_conninfo(
            host=config.db_host,
            port=config.db_port,
            dbname=config.db_name,
            user=user,
            password=password,
            sslmode=config.db_sslmode,
            connect_timeout=5,
            application_name=config.app_name,
        )
        # open=True connects in the background without blocking startup, so the
        # container comes up (and /health passes) even if the database is briefly
        # unreachable. /ready reports the real database state.
        self._pool = ConnectionPool(
            conninfo, min_size=1, max_size=4, timeout=5, open=True, name="app"
        )
        self._schema_ready = False
        self._schema_lock = threading.Lock()

    def _ensure_schema(self, conn) -> None:
        if self._schema_ready:
            return
        with self._schema_lock:
            if self._schema_ready:
                return
            conn.execute(
                "CREATE TABLE IF NOT EXISTS visits ("
                " id smallint PRIMARY KEY,"
                " count bigint NOT NULL DEFAULT 0)"
            )
            conn.execute("INSERT INTO visits (id, count) VALUES (1, 0) ON CONFLICT (id) DO NOTHING")
            self._schema_ready = True

    def ping(self) -> bool:
        try:
            with self._pool.connection(timeout=2) as conn:
                conn.execute("SELECT 1")
            return True
        except Exception:
            log.warning("database ping failed", exc_info=True)
            return False

    def get_visits(self) -> int:
        with self._pool.connection() as conn:
            self._ensure_schema(conn)
            row = conn.execute("SELECT count FROM visits WHERE id = 1").fetchone()
            return int(row[0]) if row else 0

    def increment_visits(self) -> int:
        with self._pool.connection() as conn:
            self._ensure_schema(conn)
            row = conn.execute(
                "UPDATE visits SET count = count + 1 WHERE id = 1 RETURNING count"
            ).fetchone()
            return int(row[0])


def create_store(config: Config) -> Store:
    return PostgresStore(config) if config.database_enabled else InMemoryStore()
