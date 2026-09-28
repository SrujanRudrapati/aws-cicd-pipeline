#!/usr/bin/env python3
"""loadtest: a small, dependency-free HTTP load generator with latency budgets.

Each worker thread holds one keep-alive connection (the way the ALB talks to
targets), sends its share of requests, and records per-request latency. The
run fails if any budget is blown:

  --p95-ms / --p99-ms   absolute latency ceilings
  --max-error-rate      non-2xx/3xx responses and connection errors
  --min-rps             throughput floor
  --baseline FILE       a previous --json result; fail if p95/p99 regress by
                        more than --max-regression (and by more than
                        --regression-floor-ms, so sub-millisecond noise on a
                        shared CI runner doesn't fail builds)

Exit status is 0 when every budget passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import http.client
import json
import math
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from urllib.parse import urlsplit


@dataclass
class Target:
    scheme: str
    host: str
    port: int
    path: str
    method: str = "GET"

    @classmethod
    def from_url(cls, url: str, method: str = "GET") -> Target:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise ValueError(f"unsupported URL scheme: {url!r}")
        port = parts.port or (443 if parts.scheme == "https" else 80)
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        return cls(parts.scheme, parts.hostname or "localhost", port, path, method.upper())

    @property
    def url(self) -> str:
        return f"{self.scheme}://{self.host}:{self.port}{self.path}"

    def connect(self, timeout: float) -> http.client.HTTPConnection:
        conn_cls = (
            http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        )
        return conn_cls(self.host, self.port, timeout=timeout)


@dataclass
class WorkerResult:
    latencies_ms: list[float] = field(default_factory=list)
    statuses: Counter = field(default_factory=Counter)
    errors: int = 0


def run_worker(target: Target, count: int, timeout: float) -> WorkerResult:
    result = WorkerResult()
    conn = None
    for _ in range(count):
        if conn is None:
            conn = target.connect(timeout)
        start = time.perf_counter()
        try:
            conn.request(target.method, target.path, headers={"User-Agent": "loadtest/1.0"})
            resp = conn.getresponse()
            resp.read()
        except (OSError, http.client.HTTPException) as exc:
            result.errors += 1
            result.statuses[type(exc).__name__] += 1
            conn.close()
            conn = None
            continue
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        result.statuses[str(resp.status)] += 1
        if 200 <= resp.status < 400:
            result.latencies_ms.append(elapsed_ms)
        else:
            result.errors += 1
        if resp.will_close:
            conn.close()
            conn = None
    if conn is not None:
        conn.close()
    return result


def percentile(sorted_values: list[float], pct: float) -> float:
    """Linear-interpolated percentile (same method as numpy's default)."""
    if not sorted_values:
        return math.nan
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (pct / 100.0) * (len(sorted_values) - 1)
    lo, hi = math.floor(rank), math.ceil(rank)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (rank - lo)


def split_requests(total: int, workers: int) -> list[int]:
    return [total // workers + (1 if i < total % workers else 0) for i in range(workers)]


def summarize(results: list[WorkerResult], duration_s: float) -> dict:
    latencies = sorted(x for r in results for x in r.latencies_ms)
    statuses: Counter = Counter()
    for r in results:
        statuses.update(r.statuses)
    errors = sum(r.errors for r in results)
    total = len(latencies) + errors

    def ms(value: float) -> float | None:
        return None if math.isnan(value) else round(value, 2)

    return {
        "requests": total,
        "ok": len(latencies),
        "errors": errors,
        "error_rate": round(errors / total, 4) if total else 0.0,
        "duration_s": round(duration_s, 3),
        "rps": round(total / duration_s, 1) if duration_s > 0 else 0.0,
        "latency_ms": {
            "min": ms(latencies[0]) if latencies else None,
            "mean": ms(sum(latencies) / len(latencies)) if latencies else None,
            "p50": ms(percentile(latencies, 50)),
            "p90": ms(percentile(latencies, 90)),
            "p95": ms(percentile(latencies, 95)),
            "p99": ms(percentile(latencies, 99)),
            "max": ms(latencies[-1]) if latencies else None,
        },
        "statuses": dict(statuses),
    }


def evaluate(summary: dict, args: argparse.Namespace, baseline: dict | None) -> list[tuple]:
    """Return [(name, passed, detail), ...]."""
    lat = summary["latency_ms"]
    results = []

    def ceiling(name: str, value: float | None, limit: float | None, unit: str = "ms") -> None:
        if limit is None:
            return
        if value is None:
            results.append((name, False, "no successful requests to measure"))
            return
        results.append((name, value <= limit, f"{value:g} {unit} <= {limit:g} {unit}"))

    ceiling("p95 latency", lat["p95"], args.p95_ms)
    ceiling("p99 latency", lat["p99"], args.p99_ms)
    results.append(
        (
            "error rate",
            summary["error_rate"] <= args.max_error_rate,
            f"{summary['error_rate']:.2%} <= {args.max_error_rate:.2%} "
            f"({summary['errors']} of {summary['requests']})",
        )
    )
    if args.min_rps:
        results.append(
            (
                "throughput",
                summary["rps"] >= args.min_rps,
                f"{summary['rps']} >= {args.min_rps} rps",
            )
        )

    if baseline:
        for key in ("p95", "p99"):
            before = (baseline.get("latency_ms") or {}).get(key)
            now = lat[key]
            if before is None or now is None:
                continue
            allowed = max(before * (1 + args.max_regression), before + args.regression_floor_ms)
            results.append(
                (
                    f"{key} vs baseline",
                    now <= allowed,
                    f"{before:g} -> {now:g} ms (allowed up to {allowed:.2f} ms)",
                )
            )
    return results


def render(target: Target, args: argparse.Namespace, summary: dict, verdicts: list) -> str:
    lat = summary["latency_ms"]

    def fmt(v):
        return "-" if v is None else f"{v:g}"

    statuses = "  ".join(f"{k}x{v}" for k, v in sorted(summary["statuses"].items()))
    lines = [
        f"loadtest  {target.method} {target.url}  requests={args.requests} "
        f"concurrency={args.concurrency}",
        f"  throughput  {summary['rps']} req/s over {summary['duration_s']} s",
        f"  errors      {summary['errors']} ({summary['error_rate']:.2%})",
        f"  latency ms  min {fmt(lat['min'])}  p50 {fmt(lat['p50'])}  p90 {fmt(lat['p90'])}  "
        f"p95 {fmt(lat['p95'])}  p99 {fmt(lat['p99'])}  max {fmt(lat['max'])}",
        f"  status      {statuses or '-'}",
        "",
        f"{'BUDGET':<18} {'RESULT':<6} DETAIL",
    ]
    for name, passed, detail in verdicts:
        lines.append(f"{name:<18} {'PASS' if passed else 'FAIL':<6} {detail}")
    lines += ["", "RESULT: " + ("PASS" if all(v[1] for v in verdicts) else "FAIL")]
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--url", required=True)
    p.add_argument("--method", default="GET")
    p.add_argument("--requests", type=int, default=2000)
    p.add_argument("--concurrency", type=int, default=16)
    p.add_argument("--warmup", type=int, default=50, help="unmeasured requests sent first")
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--p95-ms", type=float)
    p.add_argument("--p99-ms", type=float)
    p.add_argument("--max-error-rate", type=float, default=0.0)
    p.add_argument("--min-rps", type=float, default=0.0)
    p.add_argument("--baseline", help="previous --json result to compare against")
    p.add_argument("--max-regression", type=float, default=0.5, help="0.5 = 50%% slower")
    p.add_argument("--regression-floor-ms", type=float, default=5.0)
    p.add_argument("--json", metavar="PATH", help="write the summary as JSON")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.requests < 1 or args.concurrency < 1:
        print("--requests and --concurrency must be >= 1", file=sys.stderr)
        return 2
    target = Target.from_url(args.url, args.method)

    if args.warmup:
        run_worker(target, args.warmup, args.timeout)

    workers = min(args.concurrency, args.requests)
    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(run_worker, target, n, args.timeout)
            for n in split_requests(args.requests, workers)
        ]
        results = [f.result() for f in futures]
    duration = time.perf_counter() - start

    summary = summarize(results, duration)
    baseline = None
    if args.baseline:
        with open(args.baseline, encoding="utf-8") as fh:
            baseline = json.load(fh)
    verdicts = evaluate(summary, args, baseline)
    summary["budgets"] = [{"name": n, "passed": ok, "detail": d} for n, ok, d in verdicts]
    summary["target"] = {"method": target.method, "url": target.url}

    print(render(target, args, summary, verdicts))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2)
    return 0 if all(v[1] for v in verdicts) else 1


if __name__ == "__main__":
    sys.exit(main())
