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
        /bin/bash "${test_script}" "$@"
}

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

release_dir="${app_dir}/runtime-config/releases/${CONFIG_DIGEST#sha256:}"
printf '\n# tampered\n' >>"${release_dir}/compose.yaml"

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
