import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from perf import loadtest


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive, like the real target

    def do_GET(self):  # noqa: N802
        status = 500 if self.path.startswith("/fail") else 200
        body = b'{"ok": true}'
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def server():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}"
    httpd.shutdown()


def test_percentile_interpolates():
    values = [1.0, 2.0, 3.0, 4.0, 5.0]
    assert loadtest.percentile(values, 50) == 3.0
    assert loadtest.percentile(values, 95) == pytest.approx(4.8)
    assert loadtest.percentile([7.0], 99) == 7.0


def test_split_requests_is_exact():
    assert loadtest.split_requests(10, 3) == [4, 3, 3]
    assert sum(loadtest.split_requests(2003, 16)) == 2003


def test_target_from_url():
    t = loadtest.Target.from_url("http://example.com:8080/api/info?x=1", "post")
    assert (t.host, t.port, t.path, t.method) == ("example.com", 8080, "/api/info?x=1", "POST")
    assert loadtest.Target.from_url("https://example.com").port == 443
    with pytest.raises(ValueError):
        loadtest.Target.from_url("ftp://example.com")


def test_evaluate_baseline_regression():
    args = loadtest.build_parser().parse_args(
        ["--url", "http://x", "--p95-ms", "100", "--max-regression", "0.5"]
    )
    summary = {
        "latency_ms": {"p95": 40.0, "p99": 60.0},
        "error_rate": 0.0,
        "errors": 0,
        "requests": 100,
        "rps": 500.0,
    }
    verdicts = {
        n: ok
        for n, ok, _ in loadtest.evaluate(summary, args, {"latency_ms": {"p95": 20.0, "p99": 58.0}})
    }
    assert verdicts["p95 latency"] is True
    assert verdicts["p95 vs baseline"] is False  # 20 -> 40 ms is a 100% regression
    assert verdicts["p99 vs baseline"] is True


def test_run_passes_against_healthy_server(server, tmp_path):
    out = tmp_path / "perf.json"
    code = loadtest.main(
        [
            "--url",
            f"{server}/ok",
            "--requests",
            "300",
            "--concurrency",
            "6",
            "--warmup",
            "10",
            "--p95-ms",
            "1000",
            "--json",
            str(out),
        ]
    )
    assert code == 0
    summary = json.loads(out.read_text())
    assert summary["requests"] == 300
    assert summary["errors"] == 0
    assert summary["statuses"] == {"200": 300}


def test_run_fails_on_server_errors(server):
    code = loadtest.main(
        ["--url", f"{server}/fail", "--requests", "20", "--concurrency", "2", "--warmup", "0"]
    )
    assert code == 1
