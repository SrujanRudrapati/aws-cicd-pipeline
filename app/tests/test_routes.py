from webapp import create_app
from webapp.config import Config


class DownStore:
    backend = "postgres"

    def ping(self):
        return False

    def get_visits(self):
        raise RuntimeError("db down")

    def increment_visits(self):
        raise RuntimeError("db down")


def test_health_is_dependency_free(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_index_reports_version_and_environment(client):
    body = client.get("/").get_json()
    assert body["version"] == "test-sha"
    assert body["environment"] == "test"


def test_version_endpoint_used_by_smoke_tests(client):
    assert client.get("/version").get_json() == {"version": "test-sha"}


def test_ready_with_memory_store(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ready", "storage": "memory"}


def test_ready_returns_503_when_storage_is_down():
    app = create_app(config=Config(), store=DownStore())
    client = app.test_client()
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.get_json()["status"] == "degraded"
    # Liveness must stay green so the ALB doesn't drain the whole fleet.
    assert client.get("/health").status_code == 200


def test_info_includes_process_details(client):
    body = client.get("/api/info").get_json()
    assert {"hostname", "pid", "uptime_seconds", "storage", "version"} <= body.keys()
    assert isinstance(body["pid"], int)


def test_visits_increment(client):
    assert client.get("/api/visits").get_json()["visits"] == 0
    first = client.post("/api/visits")
    assert first.status_code == 201
    assert first.get_json()["visits"] == 1
    assert client.post("/api/visits").get_json()["visits"] == 2
    assert client.get("/api/visits").get_json()["visits"] == 2


def test_unknown_route_returns_json_404(client):
    resp = client.get("/does-not-exist")
    assert resp.status_code == 404
    assert resp.get_json() == {"error": "not found"}


def test_wrong_method_returns_json_405(client):
    resp = client.delete("/api/visits")
    assert resp.status_code == 405
    assert resp.get_json() == {"error": "method not allowed"}
