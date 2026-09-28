#!/usr/bin/env bash
# Post-deploy verification.
#
#   APP_URL=http://... EXPECTED_VERSION=<sha> [ASG_NAME=...] scripts/ci/smoke_test.sh
#
# 1. Waits for the ASG instance refresh to finish. A refresh that fails and
#    auto-rolls back (RollbackSuccessful) is still a failed deploy.
# 2. Requires N consecutive /version answers with the new version, so the ALB
#    is no longer sending traffic to any old instance.
# 3. Checks /ready and a write + read through the API, which exercises the
#    app -> RDS path (security groups, TLS, Secrets Manager credentials).
set -euo pipefail

: "${APP_URL:?}"
: "${EXPECTED_VERSION:?}"
timeout="${SMOKE_TIMEOUT:-1500}"
required="${SMOKE_CONSECUTIVE:-10}"
deadline=$(($(date +%s) + timeout))

log() { printf '[smoke %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
check_deadline() {
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "timed out after ${timeout}s: $1"
    exit 1
  fi
}
json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null || true; }

# ------------------------------------------------------------ 1. rollout
if [ -n "${ASG_NAME:-}" ]; then
  while :; do
    read -r status pct < <(aws autoscaling describe-instance-refreshes \
      --auto-scaling-group-name "$ASG_NAME" --max-records 1 \
      --query 'InstanceRefreshes[0].[Status, PercentageComplete]' --output text)
    case "$status" in
      None | Successful)
        log "instance refresh: ${status/None/none needed}"
        break
        ;;
      Pending | InProgress | Baking | Cancelling | RollbackInProgress)
        log "instance refresh: $status (${pct}% complete)"
        ;;
      "")
        log "could not read instance refresh status; retrying"
        ;;
      *)
        reason="$(aws autoscaling describe-instance-refreshes \
          --auto-scaling-group-name "$ASG_NAME" --max-records 1 \
          --query 'InstanceRefreshes[0].StatusReason' --output text)"
        log "instance refresh ended in $status: $reason"
        log "recent scaling activity:"
        aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" \
          --max-items 5 --query 'Activities[].[StartTime, StatusCode, Description]' --output text || true
        exit 1
        ;;
    esac
    check_deadline "waiting for instance refresh"
    sleep 20
  done
fi

# ------------------------------------------------ 2. new version everywhere
streak=0
while [ "$streak" -lt "$required" ]; do
  got="$(curl -fsS --max-time 5 "$APP_URL/version" 2>/dev/null | json_field version)"
  if [ "$got" = "$EXPECTED_VERSION" ]; then
    streak=$((streak + 1))
    sleep 1
  else
    [ "$streak" -gt 0 ] && log "streak reset after $streak"
    streak=0
    log "serving '${got:-<no answer>}', waiting for $EXPECTED_VERSION"
    check_deadline "waiting for $EXPECTED_VERSION to serve all traffic"
    sleep 10
  fi
done
log "$required consecutive responses from $EXPECTED_VERSION"

# ------------------------------------------------ 3. dependencies end to end
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$APP_URL/ready")" = "200" ]; do
  check_deadline "waiting for /ready (database reachable?)"
  log "/ready not 200 yet"
  sleep 10
done
log "/ready: 200"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$APP_URL/api/visits")"
if [ "$code" != "201" ]; then
  log "POST /api/visits returned $code"
  exit 1
fi
storage="$(curl -fsS --max-time 10 "$APP_URL/api/visits" | json_field storage)"
if [ "$storage" != "postgres" ]; then
  log "expected the postgres store, app reports '${storage:-<no answer>}'"
  exit 1
fi
log "write + read through the API against postgres: ok"
log "PASS"
