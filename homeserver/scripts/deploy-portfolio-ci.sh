#!/bin/bash

set -Eeuo pipefail

readonly DOCKER_BIN=/usr/local/bin/docker
readonly LOCKF_BIN=/usr/bin/lockf
readonly PYTHON_BIN=/usr/bin/python3
readonly APP_DIR=/Users/homeserver/Server/apps/portfolio
readonly ENV_FILE="${APP_DIR}/.env"
readonly LEGACY_DEPLOY_SCRIPT=/Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh
readonly RUNTIME_CONFIG_ROOT="${APP_DIR}/runtime-config"
readonly RUNTIME_CONFIG_RELEASES="${RUNTIME_CONFIG_ROOT}/releases"
readonly RUNTIME_CONFIG_STATE="${RUNTIME_CONFIG_ROOT}/state"
readonly RUNTIME_CONFIG_PENDING="${RUNTIME_CONFIG_ROOT}/pending"
readonly RUNTIME_CONFIG_CURRENT="${RUNTIME_CONFIG_ROOT}/current"
readonly RUNTIME_CONFIG_INITIALIZED="${APP_DIR}/.runtime-config-v2-initialized"
readonly OPERATION_LOCK="${APP_DIR}/.portfolio-operation.lock"
readonly IMAGE_REPOSITORY=ghcr.io/xxh3898/portfolio
readonly RUNTIME_CONFIG_REPOSITORY=ghcr.io/xxh3898/portfolio-runtime-config
readonly ZERO_SHA=0000000000000000000000000000000000000000
readonly ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000

fail() {
  printf 'Portfolio deploy bootstrap failed: %s\n' "$1" >&2
  exit "${2:-1}"
}

acquire_operation_lock() {
  local lock_status

  if [[ ! -x "${PYTHON_BIN}" ]]; then
    fail "Python is not executable: ${PYTHON_BIN}"
  fi
  if [[ ! -x "${LOCKF_BIN}" ]]; then
    fail "lockf is not executable: ${LOCKF_BIN}"
  fi
  if [[ -L "${OPERATION_LOCK}" ]] \
    || { [[ -e "${OPERATION_LOCK}" ]] && [[ ! -f "${OPERATION_LOCK}" ]]; }
  then
    fail "operation lock path must be a regular non-symlink file"
  fi

  umask 077
  if ! exec 9>>"${OPERATION_LOCK}"; then
    fail "operation lock file could not be opened"
  fi
  /bin/chmod 600 "${OPERATION_LOCK}"

  if "${LOCKF_BIN}" -s -t 0 9; then
    return 0
  else
    lock_status="$?"
  fi

  exec 9>&-
  if [[ "${lock_status}" -eq 75 ]]; then
    printf 'Another Portfolio deploy or recovery operation is already running\n' >&2
    exit 75
  fi
  fail "operation lock validation failed"
}

is_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] && [[ "$1" != "${ZERO_DIGEST}" ]]
}

is_approved_image() {
  local image="$1"
  local value

  value="${image#"${IMAGE_REPOSITORY}:"}"
  if [[ "${image}" == "${IMAGE_REPOSITORY}:${value}" ]] \
    && [[ "${value}" =~ ^[0-9a-fA-F]{40}$ ]] \
    && [[ "${value}" != "${ZERO_SHA}" ]]
  then
    return 0
  fi

  value="${image#"${IMAGE_REPOSITORY}@"}"
  [[ "${image}" == "${IMAGE_REPOSITORY}@${value}" ]] && is_digest "${value}"
}

read_env_value() {
  local key="$1"
  /usr/bin/sed -n "s/^${key}=//p" "${ENV_FILE}" | /usr/bin/tail -n 1
}

read_state_value() {
  local key="$1"
  /usr/bin/sed -n "s/^${key}=//p" "${RUNTIME_CONFIG_STATE}" \
    | /usr/bin/tail -n 1
}

state_hash_key() {
  if [[ -f "${RUNTIME_CONFIG_STATE}" && ! -L "${RUNTIME_CONFIG_STATE}" ]] \
    && /usr/bin/grep -q '^RUNTIME_CONFIG_CONTENT_SHA256=' "${RUNTIME_CONFIG_STATE}"
  then
    printf 'RUNTIME_CONFIG_CONTENT_SHA256'
  else
    printf 'RUNTIME_CONFIG_COMPOSE_SHA256'
  fi
}

state_expected_release_shape() {
  if [[ "$(state_hash_key)" == RUNTIME_CONFIG_CONTENT_SHA256 ]]; then
    printf 'synced'
  else
    printf 'legacy'
  fi
}

validate_initialization_marker() {
  if [[ ! -f "${RUNTIME_CONFIG_INITIALIZED}" ]] \
    || [[ -L "${RUNTIME_CONFIG_INITIALIZED}" ]] \
    || [[ "$(/bin/cat "${RUNTIME_CONFIG_INITIALIZED}")" != RUNTIME_CONFIG_V2=initialized ]]
  then
    fail "runtime config initialization marker is invalid"
  fi
  if ! "${PYTHON_BIN}" -c \
    'import os, stat, sys; raise SystemExit(0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o400 else 1)' \
    "${RUNTIME_CONFIG_INITIALIZED}"
  then
    fail "runtime config initialization marker mode must be 400"
  fi
}

release_shape() {
  local entries
  local release_dir="$1"
  local unexpected

  if [[ ! -d "${release_dir}" || -L "${release_dir}" ]]; then
    fail "runtime config release is missing or unsafe"
  fi
  unexpected="$(
    /usr/bin/find "${release_dir}" ! -type d ! -type f -print
  )"
  if [[ -n "${unexpected}" ]]; then
    fail "runtime config contains unsupported file types"
  fi

  entries="$(
    /usr/bin/find "${release_dir}" -mindepth 1 -print \
      | /usr/bin/sed "s#^${release_dir}/##" \
      | LC_ALL=C /usr/bin/sort
  )"
  if [[ "${entries}" == compose.yaml ]]; then
    printf 'legacy'
    return 0
  fi
  if [[ "${entries}" == $'compose.yaml\nscripts\nscripts/deploy-portfolio.sh' ]]; then
    printf 'synced'
    return 0
  fi
  fail "runtime config entry allowlist does not match"
}

validate_synced_script() {
  local release_dir="$1"
  local script="${release_dir}/scripts/deploy-portfolio.sh"

  if [[ ! -f "${script}" || -L "${script}" || ! -x "${script}" ]]; then
    fail "runtime config deploy script is missing, unsafe, or not executable"
  fi
  if ! "${PYTHON_BIN}" -c \
    'import os, stat, sys; raise SystemExit(0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o700 else 1)' \
    "${script}"
  then
    fail "runtime config deploy script mode must be 700"
  fi
  if ! /bin/bash -n "${script}"; then
    fail "runtime config deploy script syntax is invalid"
  fi
}

validate_release() {
  local release_dir="$1"
  local expected_shape="${2:-either}"
  local shape

  shape="$(release_shape "${release_dir}")"
  if [[ "${expected_shape}" != either && "${shape}" != "${expected_shape}" ]]; then
    fail "runtime config release shape is not ${expected_shape}"
  fi
  if [[ "${shape}" == synced ]]; then
    validate_synced_script "${release_dir}"
  fi
  printf '%s' "${shape}"
}

runtime_config_content_sha256() {
  local compose_hash
  local release_dir="$1"
  local script_hash
  local shape

  shape="$(validate_release "${release_dir}")"
  if [[ "${shape}" == legacy ]]; then
    /usr/bin/shasum -a 256 "${release_dir}/compose.yaml" \
      | /usr/bin/awk '{print $1}'
    return 0
  fi

  compose_hash="$(
    /usr/bin/shasum -a 256 "${release_dir}/compose.yaml" \
      | /usr/bin/awk '{print $1}'
  )"
  script_hash="$(
    /usr/bin/shasum -a 256 "${release_dir}/scripts/deploy-portfolio.sh" \
      | /usr/bin/awk '{print $1}'
  )"
  printf '%s  compose.yaml\n%s  scripts/deploy-portfolio.sh\n' \
    "${compose_hash}" \
    "${script_hash}" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}'
}

validate_state_file() {
  local application_image
  local application_revision
  local expected_legacy_keys
  local expected_synced_keys
  local hash_key
  local keys
  local previous_digest
  local previous_image
  local runtime_digest
  local runtime_hash
  local runtime_revision

  if [[ ! -f "${RUNTIME_CONFIG_STATE}" || -L "${RUNTIME_CONFIG_STATE}" ]]; then
    fail "runtime config state must be a regular non-symlink file"
  fi

  keys="$(
    /usr/bin/awk -F= 'NF >= 2 { print $1 }' "${RUNTIME_CONFIG_STATE}" \
      | LC_ALL=C /usr/bin/sort
  )"
  expected_legacy_keys=$'APPLICATION_IMAGE\nAPPLICATION_REVISION\nPREVIOUS_APPLICATION_IMAGE\nPREVIOUS_RUNTIME_CONFIG_DIGEST\nRUNTIME_CONFIG_COMPOSE_SHA256\nRUNTIME_CONFIG_DIGEST\nRUNTIME_CONFIG_REVISION'
  expected_synced_keys=$'APPLICATION_IMAGE\nAPPLICATION_REVISION\nPREVIOUS_APPLICATION_IMAGE\nPREVIOUS_RUNTIME_CONFIG_DIGEST\nRUNTIME_CONFIG_CONTENT_SHA256\nRUNTIME_CONFIG_DIGEST\nRUNTIME_CONFIG_REVISION'
  if [[ "${keys}" != "${expected_legacy_keys}" ]] \
    && [[ "${keys}" != "${expected_synced_keys}" ]]
  then
    fail "runtime config state keys are invalid"
  fi

  hash_key="$(state_hash_key)"
  application_image="$(read_state_value APPLICATION_IMAGE)"
  application_revision="$(read_state_value APPLICATION_REVISION)"
  previous_image="$(read_state_value PREVIOUS_APPLICATION_IMAGE)"
  previous_digest="$(read_state_value PREVIOUS_RUNTIME_CONFIG_DIGEST)"
  runtime_digest="$(read_state_value RUNTIME_CONFIG_DIGEST)"
  runtime_revision="$(read_state_value RUNTIME_CONFIG_REVISION)"
  runtime_hash="$(read_state_value "${hash_key}")"
  if ! is_approved_image "${application_image}" \
    || [[ ! "${application_revision}" =~ ^[0-9a-f]{40}$ ]] \
    || [[ "${application_revision}" == "${ZERO_SHA}" ]] \
    || { [[ -n "${previous_image}" ]] && ! is_approved_image "${previous_image}"; } \
    || { [[ "${previous_digest}" != "${ZERO_DIGEST}" ]] && ! is_digest "${previous_digest}"; } \
    || ! is_digest "${runtime_digest}" \
    || [[ ! "${runtime_revision}" =~ ^[0-9a-f]{40}$ ]] \
    || [[ "${runtime_revision}" == "${ZERO_SHA}" ]] \
    || [[ ! "${runtime_hash}" =~ ^[0-9a-f]{64}$ ]]
  then
    fail "runtime config state values are invalid"
  fi
}

validate_verified_state() {
  local recovery_handoff="${1:-false}"
  local current_target
  local expected_current_target
  local expected_hash
  local expected_shape
  local release_dir
  local runtime_digest
  local state_image

  if [[ ! -e "${RUNTIME_CONFIG_STATE}" && ! -L "${RUNTIME_CONFIG_STATE}" ]]; then
    if [[ -e "${RUNTIME_CONFIG_CURRENT}" || -L "${RUNTIME_CONFIG_CURRENT}" ]] \
      || [[ -e "${RUNTIME_CONFIG_INITIALIZED}" || -L "${RUNTIME_CONFIG_INITIALIZED}" ]]
    then
      fail "runtime config pointer or marker exists without verified state"
    fi
    return 0
  fi

  validate_state_file
  runtime_digest="$(read_state_value RUNTIME_CONFIG_DIGEST)"
  expected_hash="$(read_state_value "$(state_hash_key)")"
  expected_shape="$(state_expected_release_shape)"
  state_image="$(read_state_value APPLICATION_IMAGE)"
  release_dir="${RUNTIME_CONFIG_RELEASES}/${runtime_digest#sha256:}"
  validate_release "${release_dir}" "${expected_shape}" >/dev/null
  if [[ "$(runtime_config_content_sha256 "${release_dir}")" != "${expected_hash}" ]]; then
    fail "runtime config release integrity check failed"
  fi

  expected_current_target="releases/${runtime_digest#sha256:}"
  if [[ "${recovery_handoff}" == false ]]; then
    if [[ ! -L "${RUNTIME_CONFIG_CURRENT}" ]]; then
      fail "verified runtime config current pointer is missing"
    fi
    current_target="$(/usr/bin/readlink "${RUNTIME_CONFIG_CURRENT}")"
    if [[ "${current_target}" != "${expected_current_target}" ]]; then
      fail "runtime config current pointer does not match verified state"
    fi
    if [[ "$(read_env_value PORTFOLIO_IMAGE)" != "${state_image}" ]]; then
      fail "application image environment does not match verified runtime config state"
    fi
  fi

  if [[ -e "${RUNTIME_CONFIG_INITIALIZED}" || -L "${RUNTIME_CONFIG_INITIALIZED}" ]]; then
    validate_initialization_marker
  fi

  printf '%s' "${release_dir}"
}

if [[ "$#" -eq 1 && "$1" == recover && -z "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  acquire_operation_lock
  current_release="$(validate_verified_state true)"
  if [[ -n "${current_release}" ]] \
    && [[ "$(validate_release "${current_release}")" == synced ]]
  then
    exec "${current_release}/scripts/deploy-portfolio.sh" recover
  fi
  exec "${LEGACY_DEPLOY_SCRIPT}" recover
fi

if [[ "$#" -ne 0 ]]; then
  printf 'Only a direct local recover argument is allowed\n' >&2
  exit 64
fi

original_command="${SSH_ORIGINAL_COMMAND:-}"
if [[ "${original_command}" =~ ^deploy-portfolio[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  acquire_operation_lock
  exec "${LEGACY_DEPLOY_SCRIPT}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
fi

config_digest=
config_mode=
image_digest=
registry_user=
revision=

if [[ "${original_command}" =~ ^deploy-portfolio-v2[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([0-9a-f]{40})[[:space:]]keep[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  image_digest="${BASH_REMATCH[1]}"
  revision="${BASH_REMATCH[2]}"
  config_mode=keep
  registry_user="${BASH_REMATCH[3]}"
elif [[ "${original_command}" =~ ^deploy-portfolio-v2[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([0-9a-f]{40})[[:space:]]update[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  image_digest="${BASH_REMATCH[1]}"
  revision="${BASH_REMATCH[2]}"
  config_mode=update
  config_digest="${BASH_REMATCH[3]}"
  registry_user="${BASH_REMATCH[4]}"
else
  printf '%s\n' \
    'Only deploy-portfolio or strictly formatted deploy-portfolio-v2 commands are allowed' \
    >&2
  exit 64
fi

if ! is_digest "${image_digest}" \
  || [[ "${revision}" == "${ZERO_SHA}" ]] \
  || { [[ "${config_mode}" == update ]] && ! is_digest "${config_digest}"; }
then
  printf 'Portfolio deployment input is invalid\n' >&2
  exit 64
fi

acquire_operation_lock
if [[ ! -x "${DOCKER_BIN}" ]]; then
  fail "Docker CLI is not executable: ${DOCKER_BIN}"
fi
if [[ ! -f "${ENV_FILE}" || -L "${ENV_FILE}" ]]; then
  fail "production environment configuration is missing or unsafe"
fi
if [[ -e "${RUNTIME_CONFIG_PENDING}" || -L "${RUNTIME_CONFIG_PENDING}" ]]; then
  fail "an incomplete runtime config transaction requires recovery" 75
fi

current_release="$(validate_verified_state)"
candidate_release=
if [[ "${config_mode}" == keep ]]; then
  if [[ -z "${current_release}" ]] \
    || [[ "$(validate_release "${current_release}")" != synced ]]
  then
    fail "keep mode requires a verified script-enabled runtime config release"
  fi
  candidate_release="${current_release}"
fi

registry_token="$(/bin/cat)"
if [[ -z "${registry_token}" ]]; then
  printf 'GHCR token must not be empty\n' >&2
  exit 64
fi

umask 077
config_container_id=
docker_config_dir=
logged_in=false
release_temp=
token_file=

cleanup() {
  registry_token=

  if [[ -n "${config_container_id}" ]]; then
    "${DOCKER_BIN}" rm "${config_container_id}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${release_temp}" && -d "${release_temp}" ]] \
    && [[ "$(/usr/bin/basename "${release_temp}")" == .tmp.* ]]
  then
    /bin/rm -rf -- "${release_temp}"
  fi
  if [[ "${logged_in}" == true && -n "${docker_config_dir}" ]]; then
    "${DOCKER_BIN}" \
      --config "${docker_config_dir}" \
      logout ghcr.io \
      >/dev/null 2>&1 \
      || true
  fi
  if [[ -n "${docker_config_dir}" && -d "${docker_config_dir}" ]] \
    && [[ "$(/usr/bin/basename "${docker_config_dir}")" == portfolio-bootstrap-docker.* ]]
  then
    /bin/rm -rf -- "${docker_config_dir}"
  fi
  if [[ -n "${token_file}" && -f "${token_file}" ]] \
    && [[ "$(/usr/bin/basename "${token_file}")" == portfolio-token.* ]]
  then
    /bin/rm -f -- "${token_file}"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${config_mode}" == update ]]; then
  config_image="${RUNTIME_CONFIG_REPOSITORY}@${config_digest}"
  docker_config_dir="$(
    /usr/bin/mktemp -d "${TMPDIR:-/tmp}/portfolio-bootstrap-docker.XXXXXX"
  )"
  printf '%s' "${registry_token}" \
    | "${DOCKER_BIN}" \
        --config "${docker_config_dir}" \
        login ghcr.io \
        --username "${registry_user}" \
        --password-stdin \
        >/dev/null
  logged_in=true

  "${DOCKER_BIN}" \
    --config "${docker_config_dir}" \
    pull "${config_image}" \
    >/dev/null

  actual_revision="$(
    "${DOCKER_BIN}" \
      image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
      "${config_image}"
  )"
  if [[ "${actual_revision}" != "${revision}" ]]; then
    fail "runtime config revision label does not match deployment revision"
  fi
  actual_project="$(
    "${DOCKER_BIN}" \
      image inspect \
      --format '{{ index .Config.Labels "io.chochiho.runtime-config.project" }}' \
      "${config_image}"
  )"
  if [[ "${actual_project}" != portfolio ]]; then
    fail "runtime config project label is invalid"
  fi

  /bin/mkdir -p "${RUNTIME_CONFIG_RELEASES}"
  candidate_release="${RUNTIME_CONFIG_RELEASES}/${config_digest#sha256:}"
  release_temp="$(
    /usr/bin/mktemp -d "${RUNTIME_CONFIG_RELEASES}/.tmp.XXXXXX"
  )"
  config_container_id="$("${DOCKER_BIN}" create "${config_image}")"
  "${DOCKER_BIN}" cp "${config_container_id}:/runtime/." "${release_temp}"
  "${DOCKER_BIN}" rm "${config_container_id}" >/dev/null
  config_container_id=

  validate_release "${release_temp}" synced >/dev/null
  /bin/chmod 700 "${release_temp}" "${release_temp}/scripts"
  /bin/chmod 600 "${release_temp}/compose.yaml"
  /bin/chmod 700 "${release_temp}/scripts/deploy-portfolio.sh"
  validate_release "${release_temp}" synced >/dev/null

  if [[ -d "${candidate_release}" ]]; then
    validate_release "${candidate_release}" synced >/dev/null
    if ! /usr/bin/diff -qr "${release_temp}" "${candidate_release}" >/dev/null; then
      fail "existing runtime config release differs from exact digest artifact"
    fi
    /bin/rm -rf -- "${release_temp}"
    release_temp=
  else
    /bin/mv -- "${release_temp}" "${candidate_release}"
    release_temp=
  fi
fi

candidate_script="${candidate_release}/scripts/deploy-portfolio.sh"
if [[ ! -f "${candidate_script}" || -L "${candidate_script}" || ! -x "${candidate_script}" ]]; then
  fail "verified candidate deploy script is missing or unsafe"
fi

token_file="$(
  /usr/bin/mktemp "${TMPDIR:-/tmp}/portfolio-token.XXXXXX"
)"
/bin/chmod 600 "${token_file}"
printf '%s' "${registry_token}" >"${token_file}"
registry_token=
exec 3<"${token_file}"
/bin/rm -f -- "${token_file}"
token_file=

cleanup
trap - EXIT INT TERM

if [[ "${config_mode}" == update ]]; then
  exec "${candidate_script}" \
    "${image_digest}" \
    "${revision}" \
    update \
    "${config_digest}" \
    "${registry_user}" \
    <&3 3<&-
fi
exec "${candidate_script}" \
  "${image_digest}" \
  "${revision}" \
  keep \
  "${registry_user}" \
  <&3 3<&-
