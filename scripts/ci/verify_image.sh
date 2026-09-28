#!/usr/bin/env bash
# Pre-push gate for a freshly built image: nothing reaches ECR unless it passes.
#
#   scripts/ci/verify_image.sh <image>        e.g. aws-cicd-pipeline-app:<sha>
#
#   1. start the container the way production does (ulimits, worker count)
#   2. check it reports the expected version
#   3. snapshot process / socket / limit diagnostics      -> reports/diag-before.json
#   4. load test with latency + error budgets             -> reports/perf.json
#   5. diagnostics again, compared with the snapshot      -> reports/diag-after.json
#      (fd growth = leak, RSS growth, workers replaced mid-test = crash/OOM)
#
# Tunables: EXPECTED_VERSION, PERF_REQUESTS, PERF_CONCURRENCY, PERF_P95_MS,
#           PERF_P99_MS, PERF_BASELINE (a previous perf.json to compare against).
set -euo pipefail

image="${1:?usage: verify_image.sh <image>}"
name="${VERIFY_CONTAINER:-app-verify}"
port="${VERIFY_PORT:-18080}"
workers=2
url="http://127.0.0.1:$port"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
reports="$root/reports"
mkdir -p "$reports"

cleanup() {
  docker logs "$name" >"$reports/container.log" 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

diag() {
  # -i so a baseline can be piped in on stdin; runs as the image's app user.
  docker exec -i "$name" python /opt/diag/sysdiag.py \
    --port 8080 --expect-workers "$workers" "$@"
}

echo "==> start $image"
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" \
  --publish "127.0.0.1:$port:8080" \
  --ulimit nofile=65536:65536 \
  --env WEB_CONCURRENCY="$workers" \
  --env APP_ENV=ci \
  "$image" >/dev/null

for attempt in $(seq 1 30); do
  if curl -fsS --max-time 2 "$url/health" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 30 ] || [ "$(docker inspect -f '{{.State.Running}}' "$name")" != "true" ]; then
    echo "container never became healthy" >&2
    exit 1
  fi
  sleep 1
done
sleep 2 # let every worker finish booting before the baseline snapshot

if [ -n "${EXPECTED_VERSION:-}" ]; then
  version="$(curl -fsS "$url/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
  if [ "$version" != "$EXPECTED_VERSION" ]; then
    echo "image reports version '$version', expected '$EXPECTED_VERSION'" >&2
    exit 1
  fi
  echo "==> version $version"
fi

echo "==> diagnostics (baseline)"
diag --json - >"$reports/diag-before.json"

echo "==> load test"
perf_args=(
  --url "$url/api/info"
  --requests "${PERF_REQUESTS:-3000}"
  --concurrency "${PERF_CONCURRENCY:-16}"
  --p95-ms "${PERF_P95_MS:-150}"
  --p99-ms "${PERF_P99_MS:-400}"
  --json "$reports/perf.json"
)
if [ -n "${PERF_BASELINE:-}" ] && [ -f "$PERF_BASELINE" ]; then
  perf_args+=(--baseline "$PERF_BASELINE")
fi
python3 "$root/scripts/perf/loadtest.py" "${perf_args[@]}"

sleep 2 # let keep-alive connections close so CLOSE_WAIT counts are meaningful

echo "==> diagnostics (after load, compared with baseline)"
diag --baseline - --json - <"$reports/diag-before.json" >"$reports/diag-after.json"

echo "==> image verified"
