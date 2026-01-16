#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

BASE_URL="${BASE_URL:-http://localhost:8080}"
BLUE_DIRECT_URL="${BLUE_DIRECT_URL:-http://localhost:8081}"
GREEN_DIRECT_URL="${GREEN_DIRECT_URL:-http://localhost:8082}"

PRIMARY_POOL="${ACTIVE_POOL:-blue}"
case "${PRIMARY_POOL}" in
  blue)
    BACKUP_POOL="green"
    CHAOS_URL="${BLUE_DIRECT_URL}"
    ;;
  green)
    BACKUP_POOL="blue"
    CHAOS_URL="${GREEN_DIRECT_URL}"
    ;;
  *)
    echo "Unknown ACTIVE_POOL '${PRIMARY_POOL}'. Expected 'blue' or 'green'." >&2
    exit 1
    ;;
esac

log() {
  printf '[verify] %s\n' "$*" >&2
}

fetch_version() {
  local url=$1
  local tmp_headers body_file
  tmp_headers="$(mktemp)"
  body_file="$(mktemp)"

  local status app_pool release_id
  status="$(curl -sS "${url}/version" \
    --connect-timeout 1 \
    --max-time 2 \
    -o "${body_file}" \
    -D "${tmp_headers}" \
    -w "%{http_code}" || printf '000')"

  if [[ -s "${tmp_headers}" ]]; then
    app_pool="$(grep -i '^X-App-Pool:' "${tmp_headers}" | awk '{print tolower($2)}' | tr -d '\r' || true)"
    release_id="$(grep -i '^X-Release-Id:' "${tmp_headers}" | awk '{print $2}' | tr -d '\r' || true)"
  else
    app_pool=""
    release_id=""
  fi

  rm -f "${tmp_headers}" "${body_file}"
  printf '%s;%s;%s\n' "${status}" "${app_pool}" "${release_id}"
}

wait_for_ready() {
  local attempts=30
  for ((i=1; i<=attempts; i++)); do
    if result="$(fetch_version "${BASE_URL}")"; then
      local status="${result%%;*}"
      if [[ "${status}" == "200" ]]; then
        log "Baseline service healthy after ${i} attempts."
        return 0
      fi
    fi
    sleep 1
  done
  echo "Service did not become ready within ${attempts}s." >&2
  exit 1
}

assert_header_match() {
  local result=$1 expected_pool=$2
  IFS=';' read -r status pool release <<< "${result}"
  if [[ "${status}" != "200" ]]; then
    echo "Expected 200 but received ${status}" >&2
    exit 1
  fi
  if [[ "${pool}" != "${expected_pool}" ]]; then
    echo "Expected X-App-Pool=${expected_pool} but received ${pool}" >&2
    exit 1
  fi
}

log "Waiting for load balancer to serve ${PRIMARY_POOL}..."
wait_for_ready

baseline_result="$(fetch_version "${BASE_URL}")"
assert_header_match "${baseline_result}" "${PRIMARY_POOL}"
log "Baseline request routed to ${PRIMARY_POOL} as expected."

log "Triggering chaos on ${PRIMARY_POOL} pool..."
curl -sS -X POST "${CHAOS_URL}/chaos/start?mode=error" -o /dev/null

log "Polling for failover to ${BACKUP_POOL}..."
total=0
backup_hits=0
non200=0
attempt_window=15

for ((i=1; i<=attempt_window; i++)); do
  result="$(fetch_version "${BASE_URL}")"
  IFS=';' read -r status pool release <<< "${result}"
  ((total++))
  if [[ "${status}" != "200" ]]; then
    ((non200++))
    log "Attempt ${i}: received ${status}"
  else
    if [[ "${pool}" == "${BACKUP_POOL}" ]]; then
      ((backup_hits++))
    fi
    log "Attempt ${i}: status=${status} pool=${pool} release=${release}"
  fi
  sleep 1
done

if (( non200 > 0 )); then
  echo "Observed ${non200} non-200 responses during failover." >&2
  exit 1
fi

if (( backup_hits == 0 )); then
  echo "No requests were served by the ${BACKUP_POOL} pool during failover window." >&2
  exit 1
fi

required_hits=$(( (attempt_window * 95 + 99) / 100 ))
if (( backup_hits < required_hits )); then
  echo "Only ${backup_hits}/${total} requests were served by ${BACKUP_POOL}; need at least ${required_hits} for 95%%." >&2
  exit 1
fi

log "Failover behaved as expected."

log "Stopping chaos on ${PRIMARY_POOL}..."
curl -sS -X POST "${CHAOS_URL}/chaos/stop" -o /dev/null || true

log "Verification complete."
