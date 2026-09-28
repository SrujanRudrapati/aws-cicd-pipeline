"""Runtime configuration, read once from environment variables."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    app_name: str = "aws-cicd-pipeline"
    version: str = "dev"
    environment: str = "local"
    aws_region: str = "us-east-1"
    db_host: str | None = None
    db_port: int = 5432
    db_name: str = "app"
    db_user: str | None = None
    db_password: str | None = None
    db_secret_arn: str | None = None
    db_sslmode: str = "prefer"

    @property
    def database_enabled(self) -> bool:
        return bool(self.db_host)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Config:
        env = os.environ if env is None else env
        return cls(
            version=env.get("APP_VERSION", "dev"),
            environment=env.get("APP_ENV", "local"),
            aws_region=env.get("AWS_REGION", "us-east-1"),
            db_host=env.get("DB_HOST") or None,
            db_port=int(env.get("DB_PORT", "5432")),
            db_name=env.get("DB_NAME", "app"),
            db_user=env.get("DB_USER") or None,
            db_password=env.get("DB_PASSWORD") or None,
            db_secret_arn=env.get("DB_SECRET_ARN") or None,
            db_sslmode=env.get("DB_SSLMODE", "prefer"),
        )
