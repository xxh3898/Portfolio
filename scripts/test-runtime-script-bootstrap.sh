#!/bin/bash

set -Eeuo pipefail

readonly PROJECT_ROOT="$(
  CDPATH= cd -- "$(dirname -- "$0")/.." && pwd
)"
readonly BOOTSTRAP_SOURCE="${PROJECT_ROOT}/homeserver/scripts/deploy-portfolio-ci.sh"
readonly MOCK_DOCKER="${PROJECT_ROOT}/scripts/fixtures/mock-portfolio-docker.sh"
readonly MOCK_LOCKF="${PROJECT_ROOT}/scripts/fixtures/mock-portfolio-lockf.py"
readonly APP_DIGEST_ONE=sha256:1111111111111111111111111111111111111111111111111111111111111111
readonly APP_DIGEST_TWO=sha256:2222222222222222222222222222222222222222222222222222222222222222
readonly REVISION_ONE=1111111111111111111111111111111111111111
readonly REVISION_TWO=2222222222222222222222222222222222222222
readonly LEGACY_CONFIG_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
readonly CONFIG_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
readonly INVALID_CONFIG_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
readonly ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000

test_root="$(
  /usr/bin/mktemp -d "${TMPDIR:-/tmp}/portfolio-script-bootstrap-test.XXXXXX"
)"

cleanup() {
  if [[ "$(/usr/bin/basename "${test_root}")" == portfolio-script-bootstrap-test.* ]]; then
    /bin/rm -rf -- "${test_root}"
  fi
}

trap cleanup EXIT INT TERM

app_dir="${test_root}/app"
bootstrap="${test_root}/deploy-portfolio-ci.sh"
legacy_deploy_script="${test_root}/legacy-deploy.sh"
runtime_compose="${test_root}/runtime-compose.yaml"
runtime_compose_changed="${test_root}/runtime-compose-changed.yaml"
runtime_deploy_script="${test_root}/runtime-deploy.sh"
candidate_log="${test_root}/candidate.log"
legacy_log="${test_root}/legacy.log"
signal_ready="${test_root}/signal.ready"
signal_marker="${test_root}/signal.marker"
docker_log="${test_root}/docker.log"
operation_lock="${app_dir}/.portfolio-operation.lock"

/bin/mkdir -p "${app_dir}/runtime-config/releases"
/bin/cp "${PROJECT_ROOT}/homeserver/compose.yaml" "${runtime_compose}"
/bin/cp "${runtime_compose}" "${runtime_compose_changed}"
printf '\n# same digest with different content\n' >>"${runtime_compose_changed}"
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}" \
  >"${app_dir}/.env"

printf '%s\n' \
  '#!/bin/bash' \
  'set -Eeuo pipefail' \
  'printf "%s\n" "$*" >>"${FAKE_LEGACY_LOG}"' \
  >"${legacy_deploy_script}"

printf '%s\n' \
  '#!/bin/bash' \
  'set -Eeuo pipefail' \
  'if [[ "${1:-}" == recover ]]; then' \
  '  printf "recover\n" >>"${FAKE_CANDIDATE_LOG}"' \
  '  exit "${FAKE_CANDIDATE_EXIT_CODE:-0}"' \
  'fi' \
  'if { : <&3; } 2>/dev/null; then' \
  '  exit 66' \
  'fi' \
  'token="$(/bin/cat)"' \
  'if [[ "${token}" != test-token ]]; then' \
  '  exit 65' \
  'fi' \
  'printf "%s\n" "$*" >>"${FAKE_CANDIDATE_LOG}"' \
  'if [[ "${FAKE_CANDIDATE_WAIT:-false}" == true ]]; then' \
  '  : >"${FAKE_SIGNAL_READY}"' \
  '  trap '\''printf "term\n" >"${FAKE_SIGNAL_MARKER}"; exit 143'\'' TERM' \
  '  while :; do /bin/sleep 1; done' \
  'fi' \
  'exit "${FAKE_CANDIDATE_EXIT_CODE:-0}"' \
  >"${runtime_deploy_script}"

/bin/chmod 700 \
  "${legacy_deploy_script}" \
  "${runtime_deploy_script}"

/usr/bin/sed \
  -e "s#readonly DOCKER_BIN=/usr/local/bin/docker#readonly DOCKER_BIN=${MOCK_DOCKER}#" \
  -e "s#readonly LOCKF_BIN=/usr/bin/lockf#readonly LOCKF_BIN=${MOCK_LOCKF}#" \
  -e "s#readonly APP_DIR=/Users/homeserver/Server/apps/portfolio#readonly APP_DIR=${app_dir}#" \
  -e "s#readonly LEGACY_DEPLOY_SCRIPT=/Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh#readonly LEGACY_DEPLOY_SCRIPT=${legacy_deploy_script}#" \
  "${BOOTSTRAP_SOURCE}" \
  >"${bootstrap}"
/bin/chmod 700 "${bootstrap}"

legacy_release="${app_dir}/runtime-config/releases/${LEGACY_CONFIG_DIGEST#sha256:}"
/bin/mkdir -p "${legacy_release}"
/bin/cp "${runtime_compose}" "${legacy_release}/compose.yaml"
legacy_hash="$(
  /usr/bin/shasum -a 256 "${legacy_release}/compose.yaml" \
    | /usr/bin/awk '{print $1}'
)"
{
  printf 'APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}"
  printf 'APPLICATION_REVISION=%s\n' "${REVISION_ONE}"
  printf 'PREVIOUS_APPLICATION_IMAGE=\n'
  printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${ZERO_DIGEST}"
  printf 'RUNTIME_CONFIG_COMPOSE_SHA256=%s\n' "${legacy_hash}"
  printf 'RUNTIME_CONFIG_DIGEST=%s\n' "${LEGACY_CONFIG_DIGEST}"
  printf 'RUNTIME_CONFIG_REVISION=%s\n' "${REVISION_ONE}"
} >"${app_dir}/runtime-config/state"
/bin/chmod 600 "${app_dir}/runtime-config/state"
/bin/ln -s \
  "releases/${LEGACY_CONFIG_DIGEST#sha256:}" \
  "${app_dir}/runtime-config/current"

/usr/bin/env \
  FAKE_LEGACY_LOG="${legacy_log}" \
  /bin/bash "${bootstrap}" recover
/usr/bin/grep -Fxq recover "${legacy_log}"

set +e
printf 'test-token' \
  | /usr/bin/env \
      SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
      /bin/bash "${bootstrap}" \
      >/dev/null 2>&1
legacy_keep_exit_code="$?"
set -e
if [[ "${legacy_keep_exit_code}" -ne 1 ]]; then
  printf 'Keep mode must reject a legacy one-file runtime release\n' >&2
  exit 1
fi

run_update() {
  printf 'test-token' \
    | /usr/bin/env \
        SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} update ${CONFIG_DIGEST} test-user" \
        FAKE_RUNTIME_COMPOSE="${FAKE_RUNTIME_COMPOSE_OVERRIDE:-${runtime_compose}}" \
        FAKE_RUNTIME_SCRIPT="${runtime_deploy_script}" \
        FAKE_CONFIG_REVISION="${FAKE_CONFIG_REVISION:-${REVISION_TWO}}" \
        FAKE_CONFIG_PROJECT="${FAKE_CONFIG_PROJECT:-portfolio}" \
        FAKE_RUNTIME_EXTRA_DIR="${FAKE_RUNTIME_EXTRA_DIR:-false}" \
        FAKE_RUNTIME_EXTRA_FILE="${FAKE_RUNTIME_EXTRA_FILE:-false}" \
        FAKE_RUNTIME_INSECURE_SCRIPT_MODE="${FAKE_RUNTIME_INSECURE_SCRIPT_MODE:-false}" \
        FAKE_RUNTIME_INVALID_SCRIPT_SYNTAX="${FAKE_RUNTIME_INVALID_SCRIPT_SYNTAX:-false}" \
        FAKE_RUNTIME_SYMLINK="${FAKE_RUNTIME_SYMLINK:-false}" \
        FAKE_CANDIDATE_EXIT_CODE="${FAKE_CANDIDATE_EXIT_CODE:-0}" \
        FAKE_CANDIDATE_LOG="${candidate_log}" \
        FAKE_SIGNAL_READY="${signal_ready}" \
        FAKE_SIGNAL_MARKER="${signal_marker}" \
        FAKE_DOCKER_LOG="${docker_log}" \
        /bin/bash "${bootstrap}"
}

state_sha_before="$(
  /usr/bin/shasum -a 256 "${app_dir}/runtime-config/state" \
    | /usr/bin/awk '{print $1}'
)"
current_before="$(/usr/bin/readlink "${app_dir}/runtime-config/current")"

set +e
FAKE_CANDIDATE_EXIT_CODE=73 run_update >/dev/null 2>&1
candidate_failure_exit_code="$?"
set -e
if [[ "${candidate_failure_exit_code}" -ne 73 ]]; then
  printf 'Deploy bootstrap must preserve the candidate exit code\n' >&2
  exit 1
fi
candidate_release="${app_dir}/runtime-config/releases/${CONFIG_DIGEST#sha256:}"
test -x "${candidate_release}/scripts/deploy-portfolio.sh"
test ! -L "${candidate_release}/scripts/deploy-portfolio.sh"
test "$(/usr/bin/readlink "${app_dir}/runtime-config/current")" = "${current_before}"
test "$(
  /usr/bin/shasum -a 256 "${app_dir}/runtime-config/state" \
    | /usr/bin/awk '{print $1}'
)" = "${state_sha_before}"
test ! -e "${app_dir}/runtime-config/pending"

run_update
/usr/bin/grep -Fxq \
  "${APP_DIGEST_TWO} ${REVISION_TWO} update ${CONFIG_DIGEST} test-user" \
  "${candidate_log}"

content_hash="$(
  compose_hash="$(
    /usr/bin/shasum -a 256 "${candidate_release}/compose.yaml" \
      | /usr/bin/awk '{print $1}'
  )"
  script_hash="$(
    /usr/bin/shasum -a 256 "${candidate_release}/scripts/deploy-portfolio.sh" \
      | /usr/bin/awk '{print $1}'
  )"
  printf '%s  compose.yaml\n%s  scripts/deploy-portfolio.sh\n' \
    "${compose_hash}" \
    "${script_hash}" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}'
)"
{
  printf 'APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}"
  printf 'APPLICATION_REVISION=%s\n' "${REVISION_ONE}"
  printf 'PREVIOUS_APPLICATION_IMAGE=\n'
  printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${LEGACY_CONFIG_DIGEST}"
  printf 'RUNTIME_CONFIG_CONTENT_SHA256=%s\n' "${content_hash}"
  printf 'RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
  printf 'RUNTIME_CONFIG_REVISION=%s\n' "${REVISION_TWO}"
} >"${app_dir}/runtime-config/state"
/bin/chmod 600 "${app_dir}/runtime-config/state"
/bin/rm -f -- "${app_dir}/runtime-config/current"
/bin/ln -s \
  "releases/${CONFIG_DIGEST#sha256:}" \
  "${app_dir}/runtime-config/current"
printf 'RUNTIME_CONFIG_V2=initialized\n' \
  >"${app_dir}/.runtime-config-v2-initialized"
/bin/chmod 400 "${app_dir}/.runtime-config-v2-initialized"

printf 'test-token' \
  | /usr/bin/env \
      SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
      FAKE_CANDIDATE_LOG="${candidate_log}" \
      FAKE_SIGNAL_READY="${signal_ready}" \
      FAKE_SIGNAL_MARKER="${signal_marker}" \
      /bin/bash "${bootstrap}"
/usr/bin/grep -Fxq \
  "${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
  "${candidate_log}"

/usr/bin/env \
  FAKE_CANDIDATE_LOG="${candidate_log}" \
  /bin/bash "${bootstrap}" recover
/usr/bin/grep -Fxq recover "${candidate_log}"

printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}" \
  >"${app_dir}/.env"
/bin/rm -f -- "${app_dir}/runtime-config/current"
/bin/ln -s \
  "releases/${LEGACY_CONFIG_DIGEST#sha256:}" \
  "${app_dir}/runtime-config/current"
{
  printf 'PREVIOUS_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' \
    "${APP_DIGEST_ONE}"
  printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
  printf 'TARGET_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' \
    "${APP_DIGEST_TWO}"
  printf 'TARGET_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
} >"${app_dir}/runtime-config/pending"
/usr/bin/env \
  FAKE_CANDIDATE_LOG="${candidate_log}" \
  /bin/bash "${bootstrap}" recover
/usr/bin/grep -Fxq recover "${candidate_log}"
/bin/rm -f -- "${app_dir}/runtime-config/pending"
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}" \
  >"${app_dir}/.env"
/bin/rm -f -- "${app_dir}/runtime-config/current"
/bin/ln -s \
  "releases/${CONFIG_DIGEST#sha256:}" \
  "${app_dir}/runtime-config/current"

candidate_count_before_mismatch="$(
  /usr/bin/wc -l <"${candidate_log}" | /usr/bin/tr -d ' '
)"
set +e
FAKE_RUNTIME_COMPOSE_OVERRIDE="${runtime_compose_changed}" \
  run_update >/dev/null 2>&1
existing_digest_mismatch_exit_code="$?"
set -e
if [[ "${existing_digest_mismatch_exit_code}" -ne 1 ]]; then
  printf 'An existing runtime digest with different content must fail closed\n' >&2
  exit 1
fi
test "$(
  /usr/bin/wc -l <"${candidate_log}" | /usr/bin/tr -d ' '
)" = "${candidate_count_before_mismatch}"

assert_preflight_failure() {
  local label="$1"
  local candidate_count_before
  local exit_code

  candidate_count_before="$(
    /usr/bin/wc -l <"${candidate_log}" | /usr/bin/tr -d ' '
  )"
  set +e
  printf 'test-token' \
    | /usr/bin/env \
        SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} update ${INVALID_CONFIG_DIGEST} test-user" \
        FAKE_RUNTIME_COMPOSE="${FAKE_RUNTIME_COMPOSE_OVERRIDE:-${runtime_compose}}" \
        FAKE_RUNTIME_SCRIPT="${runtime_deploy_script}" \
        FAKE_CONFIG_REVISION="${FAKE_CONFIG_REVISION:-${REVISION_TWO}}" \
        FAKE_CONFIG_PROJECT="${FAKE_CONFIG_PROJECT:-portfolio}" \
        FAKE_RUNTIME_EXTRA_DIR="${FAKE_RUNTIME_EXTRA_DIR:-false}" \
        FAKE_RUNTIME_EXTRA_FILE="${FAKE_RUNTIME_EXTRA_FILE:-false}" \
        FAKE_RUNTIME_INSECURE_SCRIPT_MODE="${FAKE_RUNTIME_INSECURE_SCRIPT_MODE:-false}" \
        FAKE_RUNTIME_INVALID_SCRIPT_SYNTAX="${FAKE_RUNTIME_INVALID_SCRIPT_SYNTAX:-false}" \
        FAKE_RUNTIME_SYMLINK="${FAKE_RUNTIME_SYMLINK:-false}" \
        FAKE_CANDIDATE_LOG="${candidate_log}" \
        FAKE_DOCKER_LOG="${docker_log}" \
        /bin/bash "${bootstrap}" \
        >/dev/null 2>&1
  exit_code="$?"
  set -e
  if [[ "${exit_code}" -ne 1 ]]; then
    printf '%s must fail before candidate execution\n' "${label}" >&2
    exit 1
  fi
  test "$(
    /usr/bin/wc -l <"${candidate_log}" | /usr/bin/tr -d ' '
  )" = "${candidate_count_before}"
  test "$(/usr/bin/readlink "${app_dir}/runtime-config/current")" \
    = "releases/${CONFIG_DIGEST#sha256:}"
  test ! -e "${app_dir}/runtime-config/pending"
}

FAKE_RUNTIME_INVALID_SCRIPT_SYNTAX=true \
  assert_preflight_failure 'invalid candidate deploy syntax'
FAKE_RUNTIME_INSECURE_SCRIPT_MODE=true \
  assert_preflight_failure 'insecure candidate script mode'
FAKE_RUNTIME_EXTRA_FILE=true \
  assert_preflight_failure 'unexpected artifact file'
FAKE_RUNTIME_EXTRA_DIR=true \
  assert_preflight_failure 'unexpected artifact directory'
FAKE_RUNTIME_SYMLINK=true \
  assert_preflight_failure 'artifact symlink'
FAKE_CONFIG_PROJECT=other-project \
  assert_preflight_failure 'runtime artifact project mismatch'
FAKE_CONFIG_REVISION="${REVISION_ONE}" \
  assert_preflight_failure 'runtime artifact revision mismatch'

set +e
SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user; touch ${test_root}/injected" \
  /bin/bash "${bootstrap}" >/dev/null 2>&1
injection_exit_code="$?"
/bin/bash "${bootstrap}" recover extra >/dev/null 2>&1
extra_argument_exit_code="$?"
set -e
if [[ "${injection_exit_code}" -ne 64 || "${extra_argument_exit_code}" -ne 64 ]]; then
  printf 'Deploy bootstrap must reject command injection and extra arguments\n' >&2
  exit 1
fi
test ! -e "${test_root}/injected"

set +e
printf 'test-token' \
  | /usr/bin/env \
      SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
      FAKE_CANDIDATE_WAIT=true \
      FAKE_CANDIDATE_LOG="${candidate_log}" \
      FAKE_SIGNAL_READY="${signal_ready}" \
      FAKE_SIGNAL_MARKER="${signal_marker}" \
      /bin/bash "${bootstrap}" &
signal_pid="$!"
set -e

ready_attempt=0
while [[ ! -f "${signal_ready}" && "${ready_attempt}" -lt 50 ]]; do
  /bin/sleep 0.1
  ready_attempt=$((ready_attempt + 1))
done
if [[ ! -f "${signal_ready}" ]]; then
  printf 'Candidate did not become ready for the lock and signal test\n' >&2
  exit 1
fi

candidate_count_before_contention="$(
  /usr/bin/wc -l <"${candidate_log}" | /usr/bin/tr -d ' '
)"
set +e
printf 'test-token' \
  | /usr/bin/env \
      SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
      FAKE_CANDIDATE_LOG="${candidate_log}" \
      /bin/bash "${bootstrap}" \
      >/dev/null 2>&1
contention_exit_code="$?"
set -e
if [[ "${contention_exit_code}" -ne 75 ]]; then
  printf 'Concurrent Portfolio deployment must fail with exit 75\n' >&2
  exit 1
fi
test "$(
  /usr/bin/wc -l <"${candidate_log}" | /usr/bin/tr -d ' '
)" = "${candidate_count_before_contention}"

/bin/kill -TERM "${signal_pid}"
set +e
wait "${signal_pid}"
signal_exit_code="$?"
set -e
if [[ "${signal_exit_code}" -ne 143 ]]; then
  printf 'Deploy bootstrap must transfer TERM handling to the candidate\n' >&2
  exit 1
fi
/usr/bin/grep -Fxq term "${signal_marker}"

/usr/bin/python3 -c '
import os
import stat
import sys

raise SystemExit(
    0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600 else 1
)
' "${operation_lock}"

printf 'TARGET_APPLICATION_IMAGE=invalid\n' \
  >"${app_dir}/runtime-config/pending"
set +e
printf 'test-token' \
  | /usr/bin/env \
      SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
      FAKE_CANDIDATE_LOG="${candidate_log}" \
      /bin/bash "${bootstrap}" \
      >/dev/null 2>&1
pending_exit_code="$?"
set -e
if [[ "${pending_exit_code}" -ne 75 ]]; then
  printf 'Deployment must fail while runtime recovery is pending\n' >&2
  exit 1
fi
/bin/rm -f -- "${app_dir}/runtime-config/pending"

/bin/rm -f -- "${operation_lock}"
/bin/ln -s "${app_dir}/runtime-config/state" "${operation_lock}"
set +e
printf 'test-token' \
  | /usr/bin/env \
      SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${APP_DIGEST_TWO} ${REVISION_TWO} keep test-user" \
      FAKE_CANDIDATE_LOG="${candidate_log}" \
      /bin/bash "${bootstrap}" \
      >/dev/null 2>&1
unsafe_lock_exit_code="$?"
set -e
if [[ "${unsafe_lock_exit_code}" -ne 1 ]]; then
  printf 'Unsafe Portfolio operation lock path must fail closed\n' >&2
  exit 1
fi

printf 'Portfolio runtime script bootstrap tests passed\n'
