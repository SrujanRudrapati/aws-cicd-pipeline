"""Small Flask service that the pipeline builds, verifies and deploys."""

from __future__ import annotations

import os
import socket
import time

from flask import Flask, jsonify

from .config import Config
from .storage import Store, create_store


def create_app(config: Config | None = None, store: Store | None = None) -> Flask:
    config = config or Config.from_env()
    store = store or create_store(config)
    started = time.monotonic()
    hostname = socket.gethostname()

    app = Flask(__name__)

    @app.get("/")
    def index():
        return jsonify(
            service=config.app_name, version=config.version, environment=config.environment
        )

    @app.get("/health")
    def health():
        # Liveness only, with no dependency checks: this is what the ALB polls, and a
        # database blip should not make every instance look unhealthy at once.
        return jsonify(status="ok")

    @app.get("/ready")
    def ready():
        db_ok = store.ping()
        body = {"status": "ready" if db_ok else "degraded", "storage": store.backend}
        return jsonify(body), (200 if db_ok else 503)

    @app.get("/version")
    def version():
        return jsonify(version=config.version)

    @app.get("/api/info")
    def info():
        return jsonify(
            service=config.app_name,
            version=config.version,
            environment=config.environment,
            hostname=hostname,
            pid=os.getpid(),
            uptime_seconds=round(time.monotonic() - started, 1),
            storage=store.backend,
        )

    @app.get("/api/visits")
    def get_visits():
        return jsonify(visits=store.get_visits(), storage=store.backend)

    @app.post("/api/visits")
    def add_visit():
        return jsonify(visits=store.increment_visits(), storage=store.backend), 201

    @app.errorhandler(404)
    def not_found(_err):
        return jsonify(error="not found"), 404

    @app.errorhandler(405)
    def method_not_allowed(_err):
        return jsonify(error="method not allowed"), 405

    @app.errorhandler(500)
    def internal_error(_err):
        return jsonify(error="internal server error"), 500

    return app
