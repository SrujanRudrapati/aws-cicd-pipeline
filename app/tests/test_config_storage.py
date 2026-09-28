import json
import sys
import types

import pytest
from webapp.config import Config
from webapp.storage import InMemoryStore, create_store, resolve_db_credentials


def test_config_from_env_defaults():
    cfg = Config.from_env({})
    assert cfg.version == "dev"
    assert cfg.database_enabled is False


def test_config_from_env_reads_database_settings():
    cfg = Config.from_env(
        {
            "APP_VERSION": "abc123",
            "APP_ENV": "prod",
            "DB_HOST": "db.internal",
            "DB_PORT": "6543",
            "DB_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:111111111111:secret:x",
            "DB_SSLMODE": "require",
        }
    )
    assert cfg.version == "abc123"
    assert cfg.database_enabled is True
    assert cfg.db_port == 6543
    assert cfg.db_sslmode == "require"


def test_create_store_uses_memory_without_db_host():
    assert isinstance(create_store(Config()), InMemoryStore)


def test_explicit_credentials_take_precedence():
    cfg = Config(db_host="db", db_user="u", db_password="p", db_secret_arn="arn:ignored")
    assert resolve_db_credentials(cfg) == ("u", "p")


def test_credentials_from_secrets_manager(monkeypatch):
    calls = {}

    class FakeClient:
        def get_secret_value(self, SecretId):  # noqa: N803 - boto3 casing
            calls["secret_id"] = SecretId
            return {"SecretString": json.dumps({"username": "appadmin", "password": "s3cret"})}

    fake_boto3 = types.SimpleNamespace(client=lambda service, region_name: FakeClient())
    monkeypatch.setitem(sys.modules, "boto3", fake_boto3)

    cfg = Config(db_host="db", db_secret_arn="arn:aws:secretsmanager:us-east-1:1:secret:db")
    assert resolve_db_credentials(cfg) == ("appadmin", "s3cret")
    assert calls["secret_id"] == cfg.db_secret_arn


def test_missing_credentials_is_a_clear_error():
    with pytest.raises(RuntimeError, match="DB_SECRET_ARN"):
        resolve_db_credentials(Config(db_host="db"))


def test_in_memory_store_is_thread_safe():
    import threading

    store = InMemoryStore()
    threads = [
        threading.Thread(target=lambda: [store.increment_visits() for _ in range(500)])
        for _ in range(8)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert store.get_visits() == 4000
