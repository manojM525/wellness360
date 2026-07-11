#!/usr/bin/env bash
set -euo pipefail

# Required env var: APP_URL (e.g. https://dev.taskmaster-devops.example.com)

MAX_ATTEMPTS=10
SLEEP_SECONDS=6

echo "Smoke testing ${APP_URL} ..."

check() {
  local path="$1"
  local expect_substring="$2"
  local attempt=1

  while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
    response=$(curl -sS -m 10 "${APP_URL}${path}" || true)
    if echo "${response}" | grep -q "${expect_substring}"; then
      echo "OK: ${path}"
      return 0
    fi
    echo "Attempt ${attempt}/${MAX_ATTEMPTS} failed for ${path}, retrying in ${SLEEP_SECONDS}s..."
    attempt=$((attempt + 1))
    sleep "${SLEEP_SECONDS}"
  done

  echo "::error::Smoke test failed for ${path} after ${MAX_ATTEMPTS} attempts. Last response: ${response}"
  return 1
}

# Health first — this is the same endpoint the ALB target group itself uses,
# so a failure here means CI is seeing exactly what production traffic would see.
check "/actuator/health" '"status":"UP"'

# Then a real business endpoint — health passing doesn't guarantee the actual
# API (and its DB connection) works; this hits the Spring Data REST
# auto-exposed collection endpoint directly.
check "/tasks" '"_links"'

echo "Smoke tests passed."
