#!/bin/bash

set -Eeuo pipefail

PROJECT_ROOT="$(
  CDPATH= cd -- "$(dirname -- "$0")/.." && pwd
)"
SOURCE_SCRIPT="${PROJECT_ROOT}/homeserver/scripts/deploy-portfolio.sh"
MOCK_DOCKER="${PROJECT_ROOT}/scripts/fixtures/mock-portfolio-docker.sh"

APP_DIGEST_ONE=sha256:1111111111111111111111111111111111111111111111111111111111111111
APP_DIGEST_TWO=sha256:2222222222222222222222222222222222222222222222222222222222222222
APP_DIGEST_THREE=sha256:3333333333333333333333333333333333333333333333333333333333333333
CONFIG_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CONFIG_DIGEST_TWO=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REVISION_ONE=1111111111111111111111111111111111111111
REVISION_TWO=2222222222222222222222222222222222222222
REVISION_THREE=3333333333333333333333333333333333333333

test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portfolio-deploy-test.XXXXXX")"
cleanup() {
  if [[ "$(/usr/bin/basename "${test_root}")" == portfolio-deploy-test.* ]]; then
    /bin/rm -rf -- "${test_root}"
  fi
}
trap cleanup EXIT INT TERM

app_dir="${test_root}/app"
test_script="${test_root}/deploy-portfolio.sh"
runtime_compose="${test_root}/runtime-compose.yaml"
/bin/mkdir -p "${app_dir}"
/bin/cp "${PROJECT_ROOT}/homeserver/compose.yaml" "${app_dir}/compose.yaml"
/bin/cp "${PROJECT_ROOT}/homeserver/compose.yaml" "${runtime_compose}"
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}" \
  >"${app_dir}/.env"

/usr/bin/sed \
  -e "s#readonly DOCKER_BIN=/usr/local/bin/docker#readonly DOCKER_BIN=${MOCK_DOCKER}#" \
  -e "s#readonly APP_DIR=/Users/homeserver/Server/apps/portfolio#readonly APP_DIR=${app_dir}#" \
  "${SOURCE_SCRIPT}" \
  >"${test_script}"
/bin/chmod 700 "${test_script}" "${MOCK_DOCKER}"

run_deploy() {
  printf 'test-token' \
    | /usr/bin/env \
        FAKE_RUNTIME_COMPOSE="${runtime_compose}" \
        FAKE_CONFIG_REVISION="${REVISION_ONE}" \
        FAKE_APP_DIGEST_ONE="${APP_DIGEST_ONE}" \
        FAKE_APP_DIGEST_TWO="${APP_DIGEST_TWO}" \
        FAKE_APP_REVISION_ONE="${REVISION_ONE}" \
        FAKE_APP_REVISION_TWO="${REVISION_TWO}" \
        FAKE_APP_REVISION_THREE="${REVISION_THREE}" \
        FAKE_DOCKER_LOG="${FAKE_DOCKER_LOG:-}" \
        FAKE_DISABLE_HEALTHCHECK="${FAKE_DISABLE_HEALTHCHECK:-false}" \
        FAKE_FAIL_CP="${FAKE_FAIL_CP:-false}" \
        FAKE_FAIL_IF_AMBIENT_IMAGE="${FAKE_FAIL_IF_AMBIENT_IMAGE:-false}" \
        FAKE_FAIL_UP="${FAKE_FAIL_UP:-false}" \
        FAKE_RENDER_IMAGE="${FAKE_RENDER_IMAGE:-}" \
        FAKE_RENDER_CONTAINER_NAME="${FAKE_RENDER_CONTAINER_NAME:-}" \
        FAKE_RENDER_HEALTHCHECK_JSON="${FAKE_RENDER_HEALTHCHECK_JSON:-}" \
        FAKE_RENDER_PROJECT_NAME="${FAKE_RENDER_PROJECT_NAME:-}" \
        FAKE_RENDER_PRIVILEGED_FROM_ENV="${FAKE_RENDER_PRIVILEGED_FROM_ENV:-false}" \
        FAKE_RENDER_POST_START_JSON="${FAKE_RENDER_POST_START_JSON:-}" \
        FAKE_RENDER_PID_MODE_JSON="${FAKE_RENDER_PID_MODE_JSON:-}" \
        FAKE_RENDER_PIDS_LIMIT="${FAKE_RENDER_PIDS_LIMIT:-}" \
        FAKE_RENDER_LOGGING_JSON="${FAKE_RENDER_LOGGING_JSON:-}" \
        FAKE_RENDER_EDGE_ATTACHMENT_JSON="${FAKE_RENDER_EDGE_ATTACHMENT_JSON:-}" \
        FAKE_RENDER_RESTART_POLICY="${FAKE_RENDER_RESTART_POLICY:-}" \
        FAKE_RENDER_SCALE="${FAKE_RENDER_SCALE:-}" \
        FAKE_RENDER_SECURITY_OPT_JSON="${FAKE_RENDER_SECURITY_OPT_JSON:-}" \
        FAKE_RENDER_TMPFS_JSON="${FAKE_RENDER_TMPFS_JSON:-}" \
        FAKE_RENDER_USER_OVERRIDE="${FAKE_RENDER_USER_OVERRIDE:-}" \
        FAKE_RENDER_USE_API_SOCKET="${FAKE_RENDER_USE_API_SOCKET:-false}" \
        FAKE_RENDER_VOLUMES_FROM_JSON="${FAKE_RENDER_VOLUMES_FROM_JSON:-}" \
        FAKE_RENDER_WEB_PROFILE="${FAKE_RENDER_WEB_PROFILE:-false}" \
        FAKE_REQUIRE_NONEMPTY_ENV_ON_DOWN="${FAKE_REQUIRE_NONEMPTY_ENV_ON_DOWN:-false}" \
        FAKE_SERVICE_HEALTH="${FAKE_SERVICE_HEALTH:-healthy}" \
        PORTFOLIO_IMAGE="${PORTFOLIO_IMAGE:-}" \
        /bin/bash "${test_script}" "$@"
}

run_recovery() {
  /usr/bin/env \
    FAKE_RUNTIME_COMPOSE="${runtime_compose}" \
    FAKE_CONFIG_REVISION="${REVISION_ONE}" \
    FAKE_APP_DIGEST_ONE="${APP_DIGEST_ONE}" \
    FAKE_APP_DIGEST_TWO="${APP_DIGEST_TWO}" \
    FAKE_APP_REVISION_ONE="${REVISION_ONE}" \
    FAKE_APP_REVISION_TWO="${REVISION_TWO}" \
    FAKE_APP_REVISION_THREE="${REVISION_THREE}" \
    FAKE_SERVICE_HEALTH="${FAKE_SERVICE_HEALTH:-healthy}" \
    /bin/bash "${test_script}" recover
}

bootstrap_docker_log="${test_root}/bootstrap-docker.log"
printf 'PORTFOLIO_IMAGE=\n' >"${app_dir}/.env"
set +e
FAKE_FAIL_UP=true \
FAKE_REQUIRE_NONEMPTY_ENV_ON_DOWN=true \
FAKE_DOCKER_LOG="${bootstrap_docker_log}" \
  run_deploy \
    "${APP_DIGEST_ONE}" \
    "${REVISION_ONE}" \
    update \
    "${CONFIG_DIGEST}" \
    test-user \
    >/dev/null 2>&1
bootstrap_exit_code="$?"
set -e
if [[ "${bootstrap_exit_code}" -eq 0 ]]; then
  printf 'Failed first deployment must fail after teardown\n' >&2
  exit 1
fi
/usr/bin/grep -Fq 'compose ' "${bootstrap_docker_log}"
/usr/bin/grep -Fq ' down' "${bootstrap_docker_log}"
/usr/bin/grep -Fxq 'PORTFOLIO_IMAGE=' "${app_dir}/.env"
test ! -e "${app_dir}/runtime-config/pending"

printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}" \
  >"${app_dir}/.env"
run_deploy \
  "${APP_DIGEST_ONE}" \
  "${REVISION_ONE}" \
  update \
  "${CONFIG_DIGEST}" \
  test-user

state_file="${app_dir}/runtime-config/state"
test -f "${state_file}"
/usr/bin/grep -Fxq "RUNTIME_CONFIG_DIGEST=${CONFIG_DIGEST}" "${state_file}"
/usr/bin/grep -Fxq "RUNTIME_CONFIG_REVISION=${REVISION_ONE}" "${state_file}"
test -L "${app_dir}/runtime-config/current"
test ! -e "${app_dir}/runtime-config/pending"

/bin/mv "${state_file}" "${state_file}.missing"
set +e
run_deploy \
  "${APP_DIGEST_TWO}" \
  "${REVISION_TWO}" \
  update \
  "${CONFIG_DIGEST_TWO}" \
  test-user \
  >/dev/null 2>&1
missing_state_exit_code="$?"
set -e
if [[ "${missing_state_exit_code}" -ne 65 ]]; then
  printf 'Deployment with a current pointer but missing state must fail\n' >&2
  exit 1
fi
/bin/mv "${state_file}.missing" "${state_file}"

/bin/ln -s missing-pending "${app_dir}/runtime-config/pending"
set +e
run_deploy \
  "${APP_DIGEST_TWO}" \
  "${REVISION_TWO}" \
  keep \
  test-user \
  >/dev/null 2>&1
dangling_pending_exit_code="$?"
set -e
if [[ "${dangling_pending_exit_code}" -ne 75 ]]; then
  printf 'Deployment with a dangling pending symlink must require recovery\n' >&2
  exit 1
fi
/bin/rm -f -- "${app_dir}/runtime-config/pending"

set +e
run_deploy "${APP_DIGEST_TWO}" test-user >/dev/null 2>&1
legacy_after_v2_exit_code="$?"
set -e
if [[ "${legacy_after_v2_exit_code}" -ne 75 ]]; then
  printf 'Legacy Portfolio deploy must be disabled after v2 state initialization\n' >&2
  exit 1
fi

PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_THREE} \
FAKE_FAIL_IF_AMBIENT_IMAGE=true \
  run_deploy \
    "${APP_DIGEST_TWO}" \
    "${REVISION_TWO}" \
    keep \
    test-user

run_deploy \
  "${APP_DIGEST_TWO}" \
  "${REVISION_TWO}" \
  keep \
  test-user

/usr/bin/grep -Fxq \
  "PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_TWO}" \
  "${app_dir}/.env"
/usr/bin/grep -Fxq "APPLICATION_REVISION=${REVISION_TWO}" "${state_file}"
/usr/bin/grep -Fxq "RUNTIME_CONFIG_DIGEST=${CONFIG_DIGEST}" "${state_file}"
/usr/bin/grep -Fxq "RUNTIME_CONFIG_REVISION=${REVISION_ONE}" "${state_file}"
test "$(/usr/bin/readlink "${app_dir}/runtime-config/current")" \
  = "releases/${CONFIG_DIGEST#sha256:}"
if /usr/bin/find "${app_dir}/runtime-config/releases" -name '.current.*' | /usr/bin/grep -q .; then
  printf 'Atomic current pointer update left an internal temporary symlink\n' >&2
  exit 1
fi

pending_file="${app_dir}/runtime-config/pending"
{
  printf 'PREVIOUS_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}"
  printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
  printf 'TARGET_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_THREE}"
  printf 'TARGET_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
} >"${pending_file}"
/bin/chmod 600 "${pending_file}"
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_THREE}" \
  >"${app_dir}/.env"

/bin/cp "${state_file}" "${state_file}.valid"
/usr/bin/sed \
  -e 's#^RUNTIME_CONFIG_REVISION=.*#RUNTIME_CONFIG_REVISION=garbage#' \
  "${state_file}.valid" >"${state_file}"
set +e
run_recovery >/dev/null 2>&1
invalid_state_recovery_exit_code="$?"
set -e
if [[ "${invalid_state_recovery_exit_code}" -ne 65 || ! -f "${pending_file}" ]]; then
  printf 'Recovery with invalid state values must fail and preserve pending\n' >&2
  exit 1
fi
/bin/mv "${state_file}.valid" "${state_file}"

set +e
run_deploy "${APP_DIGEST_ONE}" test-user >/dev/null 2>&1
legacy_pending_exit_code="$?"
set -e
if [[ "${legacy_pending_exit_code}" -ne 75 || ! -f "${pending_file}" ]]; then
  printf 'Legacy Portfolio deploy must preserve and reject pending transaction\n' >&2
  exit 1
fi

/bin/mv "${state_file}" "${state_file}.real"
/bin/ln -s "$(/usr/bin/basename "${state_file}.real")" "${state_file}"
set +e
run_recovery >/dev/null 2>&1
symlink_state_recovery_exit_code="$?"
set -e
if [[ "${symlink_state_recovery_exit_code}" -ne 65 || ! -f "${pending_file}" ]]; then
  printf 'Recovery with a symlink state must fail and preserve pending\n' >&2
  exit 1
fi
/bin/rm -f -- "${state_file}"
/bin/mv "${state_file}.real" "${state_file}"

run_recovery

test ! -e "${pending_file}"
/usr/bin/grep -Fxq \
  "PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_TWO}" \
  "${app_dir}/.env"
/usr/bin/grep -Fxq "APPLICATION_REVISION=${REVISION_TWO}" "${state_file}"

{
  printf 'PREVIOUS_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}"
  printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
  printf 'TARGET_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}"
  printf 'TARGET_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
} >"${pending_file}"
/bin/chmod 600 "${pending_file}"
run_recovery
test ! -e "${pending_file}"

release_one="${app_dir}/runtime-config/releases/${CONFIG_DIGEST#sha256:}"
release_two="${app_dir}/runtime-config/releases/${CONFIG_DIGEST_TWO#sha256:}"
/bin/cp -R "${release_one}" "${release_two}"
{
  printf 'PREVIOUS_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}"
  printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST}"
  printf 'TARGET_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_THREE}"
  printf 'TARGET_RUNTIME_CONFIG_DIGEST=%s\n' "${CONFIG_DIGEST_TWO}"
} >"${pending_file}"
/usr/bin/sed \
  -e "s#^APPLICATION_IMAGE=.*#APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_THREE}#" \
  -e "s#^APPLICATION_REVISION=.*#APPLICATION_REVISION=${REVISION_THREE}#" \
  -e "s#^PREVIOUS_APPLICATION_IMAGE=.*#PREVIOUS_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_ONE}#" \
  -e "s#^PREVIOUS_RUNTIME_CONFIG_DIGEST=.*#PREVIOUS_RUNTIME_CONFIG_DIGEST=${CONFIG_DIGEST_TWO}#" \
  -e "s#^RUNTIME_CONFIG_DIGEST=.*#RUNTIME_CONFIG_DIGEST=${CONFIG_DIGEST_TWO}#" \
  "${state_file}" >"${state_file}.target"
/bin/mv "${state_file}.target" "${state_file}"
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_THREE}" \
  >"${app_dir}/.env"

set +e
run_recovery >/dev/null 2>&1
mismatched_predecessor_exit_code="$?"
set -e
if [[ "${mismatched_predecessor_exit_code}" -ne 65 || ! -f "${pending_file}" ]]; then
  printf 'Completed target recovery with a mismatched predecessor must fail\n' >&2
  exit 1
fi
/usr/bin/sed \
  -e "s#^PREVIOUS_APPLICATION_IMAGE=.*#PREVIOUS_APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_TWO}#" \
  -e "s#^PREVIOUS_RUNTIME_CONFIG_DIGEST=.*#PREVIOUS_RUNTIME_CONFIG_DIGEST=${CONFIG_DIGEST}#" \
  "${state_file}" >"${state_file}.matched"
/bin/mv "${state_file}.matched" "${state_file}"

set +e
FAKE_SERVICE_HEALTH=unhealthy run_recovery >/dev/null 2>&1
unhealthy_recovery_exit_code="$?"
set -e
if [[ "${unhealthy_recovery_exit_code}" -ne 65 || ! -f "${pending_file}" ]]; then
  printf 'Completed target recovery must retain pending when unhealthy\n' >&2
  exit 1
fi

run_recovery

test "$(/usr/bin/readlink "${app_dir}/runtime-config/current")" \
  = "releases/${CONFIG_DIGEST_TWO#sha256:}"
test ! -e "${pending_file}"

/usr/bin/sed \
  -e "s#^APPLICATION_IMAGE=.*#APPLICATION_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_TWO}#" \
  -e "s#^APPLICATION_REVISION=.*#APPLICATION_REVISION=${REVISION_TWO}#" \
  -e "s#^RUNTIME_CONFIG_DIGEST=.*#RUNTIME_CONFIG_DIGEST=${CONFIG_DIGEST}#" \
  "${state_file}" >"${state_file}.restored"
/bin/mv "${state_file}.restored" "${state_file}"
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}" \
  >"${app_dir}/.env"
/bin/rm -f -- "${app_dir}/runtime-config/current"
/bin/ln -s "releases/${CONFIG_DIGEST#sha256:}" "${app_dir}/runtime-config/current"

printf 'UNKNOWN=value\n' >"${pending_file}"
set +e
run_recovery >/dev/null 2>&1
recovery_exit_code="$?"
set -e
if [[ "${recovery_exit_code}" -ne 65 || ! -f "${pending_file}" ]]; then
  printf 'Invalid pending recovery must fail closed\n' >&2
  exit 1
fi
/bin/rm -f -- "${pending_file}"

printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_ONE}" \
  >"${app_dir}/.env"
set +e
run_deploy \
  "${APP_DIGEST_THREE}" \
  "${REVISION_THREE}" \
  update \
  "${CONFIG_DIGEST_TWO}" \
  test-user \
  >/dev/null 2>&1
drifted_state_exit_code="$?"
set -e
if [[ "${drifted_state_exit_code}" -ne 65 ]]; then
  printf 'Update with application image state drift must fail\n' >&2
  exit 1
fi
printf 'PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@%s\n' "${APP_DIGEST_TWO}" \
  >"${app_dir}/.env"

/bin/mv "${state_file}" "${state_file}.valid"
/bin/ln -s missing-state "${state_file}"
set +e
run_deploy \
  "${APP_DIGEST_THREE}" \
  "${REVISION_THREE}" \
  update \
  "${CONFIG_DIGEST_TWO}" \
  test-user \
  >/dev/null 2>&1
dangling_state_exit_code="$?"
set -e
if [[ "${dangling_state_exit_code}" -ne 65 ]]; then
  printf 'Update with a dangling runtime config state symlink must fail\n' >&2
  exit 1
fi
/bin/rm -f -- "${state_file}"
/bin/mv "${state_file}.valid" "${state_file}"

set +e
FAKE_RENDER_RESTART_POLICY=no \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
wrong_restart_exit_code="$?"
set -e
if [[ "${wrong_restart_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a changed restart policy must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_USER_OVERRIDE=0 \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
root_user_exit_code="$?"
set -e
if [[ "${root_user_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a root user override must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_SECURITY_OPT_JSON='["no-new-privileges:true","seccomp=unconfined"]' \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
unsafe_security_opt_exit_code="$?"
set -e
if [[ "${unsafe_security_opt_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with an extra security option must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_POST_START_JSON='[{"command":["id"],"user":"root","privileged":true}]' \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
lifecycle_hook_exit_code="$?"
set -e
if [[ "${lifecycle_hook_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a privileged lifecycle hook must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_VOLUMES_FROM_JSON='["container:site-content:ro"]' \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
volumes_from_exit_code="$?"
set -e
if [[ "${volumes_from_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with volumes_from must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_USE_API_SOCKET=true \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
api_socket_exit_code="$?"
set -e
if [[ "${api_socket_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with container API socket access must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_PID_MODE_JSON='"host"' \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
host_namespace_exit_code="$?"
set -e
if [[ "${host_namespace_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with host PID namespace must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_PIDS_LIMIT=-1 \
  run_deploy "${APP_DIGEST_THREE}" "${REVISION_THREE}" keep test-user \
  >/dev/null 2>&1
unbounded_pids_exit_code="$?"
set -e
if [[ "${unbounded_pids_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with an unbounded PID limit must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_LOGGING_JSON='{"driver":"json-file"}' \
  run_deploy "${APP_DIGEST_THREE}" "${REVISION_THREE}" keep test-user \
  >/dev/null 2>&1
unbounded_logging_exit_code="$?"
set -e
if [[ "${unbounded_logging_exit_code}" -ne 1 ]]; then
  printf 'Runtime config without bounded log rotation must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_EDGE_ATTACHMENT_JSON='{"aliases":["database"]}' \
  run_deploy "${APP_DIGEST_THREE}" "${REVISION_THREE}" keep test-user \
  >/dev/null 2>&1
edge_alias_exit_code="$?"
set -e
if [[ "${edge_alias_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with an edge network alias must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_CONTAINER_NAME=database \
  run_deploy "${APP_DIGEST_THREE}" "${REVISION_THREE}" keep test-user \
  >/dev/null 2>&1
container_name_exit_code="$?"
set -e
if [[ "${container_name_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a changed container name must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_HEALTHCHECK_JSON='{"test":["CMD","wget","-q","-O","/dev/null","http://127.0.0.1:8080/health"],"interval":"1ms","timeout":"5s","start_period":"5s","retries":3}' \
  run_deploy "${APP_DIGEST_THREE}" "${REVISION_THREE}" keep test-user \
  >/dev/null 2>&1
healthcheck_schedule_exit_code="$?"
set -e
if [[ "${healthcheck_schedule_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a changed healthcheck schedule must fail\n' >&2
  exit 1
fi

printf 'PRIVILEGED=false\n' >>"${app_dir}/.env"
set +e
FAKE_RENDER_PRIVILEGED_FROM_ENV=true \
  run_deploy "${APP_DIGEST_THREE}" "${REVISION_THREE}" keep test-user \
  >/dev/null 2>&1
post_write_environment_exit_code="$?"
set -e
if [[ "${post_write_environment_exit_code}" -ne 1 ]]; then
  printf 'Runtime config that changes after environment sanitization must fail\n' >&2
  exit 1
fi
/usr/bin/sed -i '' '/^PRIVILEGED=false$/d' "${app_dir}/.env"

set +e
FAKE_RENDER_TMPFS_JSON='["/srv/site"]' \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
wrong_tmpfs_exit_code="$?"
set -e
if [[ "${wrong_tmpfs_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with an image-content tmpfs override must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_SCALE=0 \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
zero_scale_exit_code="$?"
set -e
if [[ "${zero_scale_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with zero Portfolio replicas must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_WEB_PROFILE=true \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
profiled_service_exit_code="$?"
set -e
if [[ "${profiled_service_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a profiled Portfolio service must fail\n' >&2
  exit 1
fi

set +e
FAKE_DISABLE_HEALTHCHECK=true \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
disabled_healthcheck_exit_code="$?"
set -e
if [[ "${disabled_healthcheck_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a disabled healthcheck must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_PROJECT_NAME=unexpected \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
wrong_project_exit_code="$?"
set -e
if [[ "${wrong_project_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a different Compose project name must fail\n' >&2
  exit 1
fi

set +e
FAKE_RENDER_IMAGE=ghcr.io/xxh3898/portfolio@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  run_deploy \
    "${APP_DIGEST_THREE}" \
    "${REVISION_THREE}" \
    keep \
    test-user \
    >/dev/null 2>&1
wrong_image_exit_code="$?"
set -e
if [[ "${wrong_image_exit_code}" -ne 1 ]]; then
  printf 'Runtime config with a different Portfolio image must fail\n' >&2
  exit 1
fi
/usr/bin/grep -Fxq \
  "PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_TWO}" \
  "${app_dir}/.env"

docker_log="${test_root}/docker.log"
set +e
FAKE_FAIL_CP=true \
FAKE_DOCKER_LOG="${docker_log}" \
  run_deploy \
    "${APP_DIGEST_ONE}" \
    "${REVISION_ONE}" \
    update \
    "${CONFIG_DIGEST_TWO}" \
    test-user \
    >/dev/null 2>&1
cleanup_exit_code="$?"
set -e
if [[ "${cleanup_exit_code}" -eq 0 ]]; then
  printf 'Broken runtime config extraction must fail\n' >&2
  exit 1
fi
/usr/bin/grep -Fq 'rm mock-runtime-config-container' "${docker_log}"
if /usr/bin/find "${app_dir}/runtime-config/releases" -maxdepth 1 -type d -name '.tmp.*' | /usr/bin/grep -q .; then
  printf 'Broken runtime config extraction left a temporary release\n' >&2
  exit 1
fi

release_dir="${release_one}"
printf '\n# tampered\n' >>"${release_dir}/compose.yaml"

set +e
run_deploy \
  "${APP_DIGEST_THREE}" \
  "${REVISION_THREE}" \
  update \
  "${CONFIG_DIGEST_TWO}" \
  test-user \
  >/dev/null 2>&1
update_exit_code="$?"
set -e

if [[ "${update_exit_code}" -ne 65 ]]; then
  printf 'Update with a tampered active runtime config must fail: actual=%s\n' "${update_exit_code}" >&2
  exit 1
fi

set +e
run_deploy \
  "${APP_DIGEST_THREE}" \
  "${REVISION_THREE}" \
  keep \
  test-user \
  >/dev/null 2>&1
exit_code="$?"
set -e

if [[ "${exit_code}" -ne 65 ]]; then
  printf 'Tampered runtime config must fail with exit 65: actual=%s\n' "${exit_code}" >&2
  exit 1
fi

/usr/bin/grep -Fxq \
  "PORTFOLIO_IMAGE=ghcr.io/xxh3898/portfolio@${APP_DIGEST_TWO}" \
  "${app_dir}/.env"

printf 'Portfolio deploy v2 tests passed\n'
