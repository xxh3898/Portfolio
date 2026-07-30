#!/bin/bash

set -Eeuo pipefail

readonly DOCKER_BIN=/usr/local/bin/docker
readonly PYTHON_BIN=/usr/bin/python3
readonly APP_DIR=/Users/homeserver/Server/apps/portfolio
readonly LEGACY_COMPOSE_FILE="${APP_DIR}/compose.yaml"
readonly ENV_FILE="${APP_DIR}/.env"
readonly RUNTIME_CONFIG_ROOT="${APP_DIR}/runtime-config"
readonly RUNTIME_CONFIG_RELEASES="${RUNTIME_CONFIG_ROOT}/releases"
readonly RUNTIME_CONFIG_STATE="${RUNTIME_CONFIG_ROOT}/state"
readonly RUNTIME_CONFIG_PENDING="${RUNTIME_CONFIG_ROOT}/pending"
readonly RUNTIME_CONFIG_CURRENT="${RUNTIME_CONFIG_ROOT}/current"
readonly IMAGE_REPOSITORY=ghcr.io/xxh3898/portfolio
readonly RUNTIME_CONFIG_REPOSITORY=ghcr.io/xxh3898/portfolio-runtime-config
readonly ZERO_SHA=0000000000000000000000000000000000000000
readonly ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
readonly HEALTH_TIMEOUT_SECONDS=60

unset PORTFOLIO_IMAGE

usage() {
  printf '%s\n' \
    'Usage:' \
    '  deploy-portfolio.sh <image-digest> <registry-user>' \
    '  deploy-portfolio.sh <image-digest> <commit-sha> keep <registry-user>' \
    '  deploy-portfolio.sh <image-digest> <commit-sha> update <config-digest> <registry-user>' \
    '  deploy-portfolio.sh recover' \
    >&2
}

fail() {
  printf 'Portfolio deployment refused: %s\n' "$1" >&2
  exit "${2:-65}"
}

is_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] && [[ "$1" != "${ZERO_DIGEST}" ]]
}

legacy_mode=false
recovery_mode=false
config_mode=legacy
revision=
config_digest=
image_digest=
registry_user=

case "$#" in
  1)
    if [[ "$1" != recover ]]; then
      usage
      exit 64
    fi
    recovery_mode=true
    config_mode=recover
    ;;
  2)
    legacy_mode=true
    image_digest="$1"
    registry_user="$2"
    ;;
  4)
    image_digest="$1"
    revision="$2"
    config_mode="$3"
    registry_user="$4"
    if [[ "${config_mode}" != keep ]]; then
      usage
      exit 64
    fi
    ;;
  5)
    image_digest="$1"
    revision="$2"
    config_mode="$3"
    config_digest="$4"
    registry_user="$5"
    if [[ "${config_mode}" != update ]]; then
      usage
      exit 64
    fi
    ;;
  *)
    usage
    exit 64
    ;;
esac

if [[ "${recovery_mode}" == false ]] && ! is_digest "${image_digest}"; then
  fail "image digest must use sha256 followed by 64 lowercase hexadecimal characters" 64
fi

if [[ "${legacy_mode}" == false && "${recovery_mode}" == false ]] \
  && { [[ ! "${revision}" =~ ^[0-9a-f]{40}$ ]] || [[ "${revision}" == "${ZERO_SHA}" ]]; }
then
  fail "commit SHA must contain 40 lowercase hexadecimal characters" 64
fi

if [[ "${config_mode}" == update ]] && ! is_digest "${config_digest}"; then
  fail "runtime config digest must use sha256 followed by 64 lowercase hexadecimal characters" 64
fi

if [[ "${recovery_mode}" == false && ! "${registry_user}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  fail "registry user contains unsupported characters" 64
fi

if [[ ! -x "${DOCKER_BIN}" ]]; then
  fail "Docker CLI is not executable: ${DOCKER_BIN}" 69
fi

if [[ ! -x "${PYTHON_BIN}" ]]; then
  fail "Python is not executable: ${PYTHON_BIN}" 69
fi

if [[ ! -f "${LEGACY_COMPOSE_FILE}" || ! -f "${ENV_FILE}" ]]; then
  fail "production Compose configuration is incomplete" 66
fi

if [[ "${recovery_mode}" == false ]] \
  && [[ -e "${RUNTIME_CONFIG_PENDING}" || -L "${RUNTIME_CONFIG_PENDING}" ]]
then
  fail "an incomplete runtime config transaction requires recovery" 75
fi
if [[ "${legacy_mode}" == true ]] \
  && {
    [[ -e "${RUNTIME_CONFIG_STATE}" || -L "${RUNTIME_CONFIG_STATE}" ]] \
      || [[ -e "${RUNTIME_CONFIG_CURRENT}" || -L "${RUNTIME_CONFIG_CURRENT}" ]];
  }
then
  fail "legacy deployment is disabled after runtime config state initialization" 75
fi

registry_token=
if [[ "${recovery_mode}" == false ]]; then
  registry_token="$(/bin/cat)"
  if [[ -z "${registry_token}" ]]; then
    fail "GHCR token must not be empty" 64
  fi
fi

umask 077

docker_config_dir="$(
  /usr/bin/mktemp -d "${TMPDIR:-/tmp}/portfolio-docker-config.XXXXXX"
)"
env_temp=
state_temp=
pending_temp=
release_temp=
current_link_temp=
config_container_id=
prepared_release=
logged_in=false

# shellcheck disable=SC2329
cleanup() {
  registry_token=

  if [[ -n "${config_container_id}" ]]; then
    "${DOCKER_BIN}" rm "${config_container_id}" >/dev/null 2>&1 || true
  fi

  for cleanup_path in \
    "${env_temp}" \
    "${state_temp}" \
    "${pending_temp}" \
    "${current_link_temp}"
  do
    if [[ -n "${cleanup_path}" && -e "${cleanup_path}" ]]; then
      /bin/rm -f -- "${cleanup_path}"
    fi
  done

  if [[ -n "${release_temp}" && -d "${release_temp}" ]] \
    && [[ "$(/usr/bin/basename "${release_temp}")" == .tmp.* ]]
  then
    /bin/rm -rf -- "${release_temp}"
  fi

  if [[ "${logged_in}" == true ]]; then
    "${DOCKER_BIN}" \
      --config "${docker_config_dir}" \
      logout ghcr.io \
      >/dev/null 2>&1 \
      || true
  fi

  if [[ "$(/usr/bin/basename "${docker_config_dir}")" == portfolio-docker-config.* ]]; then
    /bin/rm -rf -- "${docker_config_dir}"
  fi
}
trap cleanup EXIT INT TERM

read_env_value() {
  local key="$1"
  /usr/bin/sed -n "s/^${key}=//p" "${ENV_FILE}" | /usr/bin/tail -n 1
}

read_state_value() {
  local key="$1"
  if [[ ! -f "${RUNTIME_CONFIG_STATE}" ]]; then
    return 0
  fi
  /usr/bin/sed -n "s/^${key}=//p" "${RUNTIME_CONFIG_STATE}" | /usr/bin/tail -n 1
}

write_image_env() {
  local image="$1"

  env_temp="$(/usr/bin/mktemp "${APP_DIR}/.env.tmp.XXXXXX")"
  printf 'PORTFOLIO_IMAGE=%s\n' "${image}" >"${env_temp}"
  /bin/chmod 600 "${env_temp}"
  /bin/mv -f -- "${env_temp}" "${ENV_FILE}"
  env_temp=
}

compose_with() {
  local compose_file="$1"
  shift

  "${DOCKER_BIN}" \
    compose \
    --project-directory "$(/usr/bin/dirname "${compose_file}")" \
    --env-file "${ENV_FILE}" \
    --file "${compose_file}" \
    "$@"
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

release_dir_for_digest() {
  local digest="$1"
  printf '%s/%s\n' "${RUNTIME_CONFIG_RELEASES}" "${digest#sha256:}"
}

validate_release_files() {
  local release_dir="$1"
  local unexpected
  local files

  unexpected="$(
    /usr/bin/find "${release_dir}" ! -type d ! -type f -print
  )"
  if [[ -n "${unexpected}" ]]; then
    fail "runtime config contains unsupported file types"
  fi

  files="$(
    /usr/bin/find "${release_dir}" -type f -print \
      | /usr/bin/sed "s#^${release_dir}/##" \
      | LC_ALL=C /usr/bin/sort
  )"
  if [[ "${files}" != compose.yaml ]]; then
    fail "runtime config file allowlist does not match"
  fi
}

compose_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

validate_compose_contract() {
  local compose_file="$1"
  local image="$2"
  local rendered

  PORTFOLIO_IMAGE="${image}" \
    "${DOCKER_BIN}" \
      compose \
      --project-directory "$(/usr/bin/dirname "${compose_file}")" \
      --env-file "${ENV_FILE}" \
      --file "${compose_file}" \
      config \
      --quiet

  rendered="$(
    PORTFOLIO_IMAGE="${image}" \
      "${DOCKER_BIN}" \
        compose \
        --project-directory "$(/usr/bin/dirname "${compose_file}")" \
        --env-file "${ENV_FILE}" \
        --file "${compose_file}" \
        config \
        --format json
  )"

  printf '%s' "${rendered}" \
    | "${PYTHON_BIN}" -c '
import json
import sys

config = json.load(sys.stdin)
expected_image = sys.argv[1]
services = config.get("services", {})
networks = config.get("networks", {})
if config.get("name") != "portfolio":
    raise SystemExit("Compose project name must remain portfolio")
if set(services) != {"portfolio"}:
    raise SystemExit("unexpected Portfolio service set")
service = services["portfolio"]
if service.get("image") != expected_image:
    raise SystemExit("Portfolio image does not match the requested deployment")
if set(service.get("networks", {})) != {"edge"}:
    raise SystemExit("Portfolio must only join edge")
if service.get("ports"):
    raise SystemExit("Portfolio must not publish host ports")
if service.get("profiles"):
    raise SystemExit("Portfolio must not use Compose profiles")
if service.get("restart") != "unless-stopped":
    raise SystemExit("Portfolio restart policy must remain unless-stopped")
if (
    service.get("user") not in (None, "")
    or service.get("privileged") is True
    or service.get("cap_add")
    or service.get("devices")
    or service.get("use_api_socket") is True
):
    raise SystemExit("Portfolio must not override image user or add privileges")
if (
    service.get("volumes")
    or service.get("volumes_from")
    or service.get("configs")
    or service.get("secrets")
):
    raise SystemExit("Portfolio must serve only image-owned content")
if service.get("command") is not None or service.get("entrypoint") is not None:
    raise SystemExit("Portfolio must not override the image process")
if service.get("post_start") is not None or service.get("pre_stop") is not None:
    raise SystemExit("Portfolio must not define lifecycle hooks")
if service.get("tmpfs") != ["/tmp:size=64m,mode=1777"]:
    raise SystemExit("Portfolio tmpfs contract is invalid")
if service.get("scale", 1) != 1:
    raise SystemExit("Portfolio must run exactly one replica")
if service.get("deploy", {}).get("replicas", 1) != 1:
    raise SystemExit("Portfolio deploy replicas must remain one")
if service.get("read_only") is not True or service.get("init") is not True:
    raise SystemExit("Portfolio hardening flags are missing")
if service.get("security_opt") != ["no-new-privileges:true"]:
    raise SystemExit("Portfolio security options must remain restricted")
healthcheck = service.get("healthcheck", {})
if healthcheck.get("disable") is True or healthcheck.get("test") != [
    "CMD",
    "wget",
    "-q",
    "-O",
    "/dev/null",
    "http://127.0.0.1:8080/health",
]:
    raise SystemExit("Portfolio healthcheck contract is invalid")
edge = networks.get("edge", {})
if edge.get("external") is not True or edge.get("name") != "edge":
    raise SystemExit("Portfolio edge network contract is invalid")
' "${image}"
}

prepare_runtime_release() {
  local digest="$1"
  local expected_revision="$2"
  local config_image="${RUNTIME_CONFIG_REPOSITORY}@${digest}"
  local actual_project
  local actual_revision
  local release_dir

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
  if [[ "${actual_revision}" != "${expected_revision}" ]]; then
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
  release_dir="$(release_dir_for_digest "${digest}")"
  release_temp="$(
    /usr/bin/mktemp -d "${RUNTIME_CONFIG_RELEASES}/.tmp.XXXXXX"
  )"
  config_container_id="$(
    "${DOCKER_BIN}" create "${config_image}"
  )"
  "${DOCKER_BIN}" cp "${config_container_id}:/runtime/." "${release_temp}"
  "${DOCKER_BIN}" rm "${config_container_id}" >/dev/null
  config_container_id=

  validate_release_files "${release_temp}"
  /bin/chmod -R go-rwx "${release_temp}"

  if [[ -d "${release_dir}" ]]; then
    validate_release_files "${release_dir}"
    if ! /usr/bin/diff -qr "${release_temp}" "${release_dir}" >/dev/null; then
      fail "existing runtime config release differs from exact digest artifact"
    fi
    /bin/rm -rf -- "${release_temp}"
    release_temp=
    prepared_release="${release_dir}"
    return 0
  fi

  /bin/mv -- "${release_temp}" "${release_dir}"
  release_temp=
  prepared_release="${release_dir}"
}

write_pending_state() {
  local previous_image="$1"
  local previous_config_digest="$2"
  local target_image="$3"
  local target_config_digest="$4"

  /bin/mkdir -p "${RUNTIME_CONFIG_ROOT}"
  pending_temp="$(
    /usr/bin/mktemp "${RUNTIME_CONFIG_ROOT}/.pending.tmp.XXXXXX"
  )"
  {
    printf 'PREVIOUS_APPLICATION_IMAGE=%s\n' "${previous_image}"
    printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${previous_config_digest}"
    printf 'TARGET_APPLICATION_IMAGE=%s\n' "${target_image}"
    printf 'TARGET_RUNTIME_CONFIG_DIGEST=%s\n' "${target_config_digest}"
  } >"${pending_temp}"
  /bin/chmod 600 "${pending_temp}"
  /bin/mv -f -- "${pending_temp}" "${RUNTIME_CONFIG_PENDING}"
  pending_temp=
}

replace_current_link() {
  local release_dir="$1"

  current_link_temp="${RUNTIME_CONFIG_ROOT}/.current.$$"
  /bin/ln -s "releases/$("/usr/bin/basename" "${release_dir}")" "${current_link_temp}"
  "${PYTHON_BIN}" -c \
    'import os, sys; os.replace(sys.argv[1], sys.argv[2])' \
    "${current_link_temp}" \
    "${RUNTIME_CONFIG_CURRENT}"
  current_link_temp=
}

write_success_state() {
  local application_image="$1"
  local application_revision="$2"
  local runtime_config_digest="$3"
  local runtime_config_revision="$4"
  local previous_image="$5"
  local previous_config_digest="$6"
  local release_dir="$7"
  local compose_digest="$8"

  state_temp="$(
    /usr/bin/mktemp "${RUNTIME_CONFIG_ROOT}/.state.tmp.XXXXXX"
  )"
  {
    printf 'APPLICATION_IMAGE=%s\n' "${application_image}"
    printf 'APPLICATION_REVISION=%s\n' "${application_revision}"
    printf 'RUNTIME_CONFIG_DIGEST=%s\n' "${runtime_config_digest}"
    printf 'RUNTIME_CONFIG_REVISION=%s\n' "${runtime_config_revision}"
    printf 'RUNTIME_CONFIG_COMPOSE_SHA256=%s\n' "${compose_digest}"
    printf 'PREVIOUS_APPLICATION_IMAGE=%s\n' "${previous_image}"
    printf 'PREVIOUS_RUNTIME_CONFIG_DIGEST=%s\n' "${previous_config_digest}"
  } >"${state_temp}"
  /bin/chmod 600 "${state_temp}"
  /bin/mv -f -- "${state_temp}" "${RUNTIME_CONFIG_STATE}"
  state_temp=

  replace_current_link "${release_dir}"
  /bin/rm -f -- "${RUNTIME_CONFIG_PENDING}"
}

read_pending_value() {
  local key="$1"
  local value

  value="$(
    /usr/bin/awk -F= -v key="${key}" '
      $1 == key {
        value = substr($0, index($0, "=") + 1)
        count += 1
      }
      END {
        if (count != 1) {
          exit 1
        }
        print value
      }
    ' "${RUNTIME_CONFIG_PENDING}"
  )" || fail "${key} must appear exactly once in ${RUNTIME_CONFIG_PENDING}"

  printf '%s' "${value}"
}

validate_pending_state() {
  local keys

  if [[ ! -f "${RUNTIME_CONFIG_PENDING}" || -L "${RUNTIME_CONFIG_PENDING}" ]]; then
    fail "runtime config recovery requires a regular pending state file"
  fi

  keys="$(
    /usr/bin/awk -F= 'NF >= 2 { print $1 }' "${RUNTIME_CONFIG_PENDING}" \
      | LC_ALL=C /usr/bin/sort
  )"
  if [[ "${keys}" != $'PREVIOUS_APPLICATION_IMAGE\nPREVIOUS_RUNTIME_CONFIG_DIGEST\nTARGET_APPLICATION_IMAGE\nTARGET_RUNTIME_CONFIG_DIGEST' ]]; then
    fail "runtime config pending state keys are invalid"
  fi
}

validate_state_file() {
  local application_image
  local application_revision
  local keys
  local previous_image
  local previous_digest
  local runtime_digest
  local runtime_revision
  local runtime_compose_sha

  if [[ ! -f "${RUNTIME_CONFIG_STATE}" || -L "${RUNTIME_CONFIG_STATE}" ]]; then
    fail "runtime config state must be a regular non-symlink file"
  fi
  keys="$(
    /usr/bin/awk -F= 'NF >= 2 { print $1 }' "${RUNTIME_CONFIG_STATE}" \
      | LC_ALL=C /usr/bin/sort
  )"
  if [[ "${keys}" != $'APPLICATION_IMAGE\nAPPLICATION_REVISION\nPREVIOUS_APPLICATION_IMAGE\nPREVIOUS_RUNTIME_CONFIG_DIGEST\nRUNTIME_CONFIG_COMPOSE_SHA256\nRUNTIME_CONFIG_DIGEST\nRUNTIME_CONFIG_REVISION' ]]; then
    fail "runtime config state keys are invalid"
  fi

  application_image="$(read_state_value APPLICATION_IMAGE)"
  application_revision="$(read_state_value APPLICATION_REVISION)"
  previous_image="$(read_state_value PREVIOUS_APPLICATION_IMAGE)"
  previous_digest="$(read_state_value PREVIOUS_RUNTIME_CONFIG_DIGEST)"
  runtime_digest="$(read_state_value RUNTIME_CONFIG_DIGEST)"
  runtime_revision="$(read_state_value RUNTIME_CONFIG_REVISION)"
  runtime_compose_sha="$(read_state_value RUNTIME_CONFIG_COMPOSE_SHA256)"
  if ! is_approved_image "${application_image}" \
    || [[ ! "${application_revision}" =~ ^[0-9a-f]{40}$ ]] \
    || [[ "${application_revision}" == "${ZERO_SHA}" ]] \
    || { [[ -n "${previous_image}" ]] && ! is_approved_image "${previous_image}"; } \
    || { [[ "${previous_digest}" != "${ZERO_DIGEST}" ]] && ! is_digest "${previous_digest}"; } \
    || ! is_digest "${runtime_digest}" \
    || [[ ! "${runtime_revision}" =~ ^[0-9a-f]{40}$ ]] \
    || [[ "${runtime_revision}" == "${ZERO_SHA}" ]] \
    || [[ ! "${runtime_compose_sha}" =~ ^[0-9a-f]{64}$ ]]
  then
    fail "runtime config state values are invalid"
  fi
}

validate_verified_release() {
  local digest="$1"
  local expected_compose_sha="$2"
  local release_dir

  if ! is_digest "${digest}" || [[ ! "${expected_compose_sha}" =~ ^[0-9a-f]{64}$ ]]; then
    fail "runtime config state is invalid"
  fi

  release_dir="$(release_dir_for_digest "${digest}")"
  if [[ ! -d "${release_dir}" ]]; then
    fail "runtime config release is missing during recovery"
  fi
  validate_release_files "${release_dir}"
  if [[ "$(compose_sha256 "${release_dir}/compose.yaml")" != "${expected_compose_sha}" ]]; then
    fail "runtime config release integrity check failed during recovery"
  fi

  printf '%s' "${release_dir}"
}

recover_pending_transaction() {
  local previous_image
  local previous_digest
  local target_image
  local target_digest
  local state_image
  local state_digest
  local state_compose_sha
  local state_previous_image
  local state_previous_digest
  local recovery_release
  local recovery_compose
  local expected_current
  local running_services

  validate_pending_state
  if [[ -e "${RUNTIME_CONFIG_STATE}" || -L "${RUNTIME_CONFIG_STATE}" ]]; then
    validate_state_file
  fi
  previous_image="$(read_pending_value PREVIOUS_APPLICATION_IMAGE)"
  previous_digest="$(read_pending_value PREVIOUS_RUNTIME_CONFIG_DIGEST)"
  target_image="$(read_pending_value TARGET_APPLICATION_IMAGE)"
  target_digest="$(read_pending_value TARGET_RUNTIME_CONFIG_DIGEST)"

  if { [[ -n "${previous_image}" ]] && ! is_approved_image "${previous_image}"; } \
    || ! is_approved_image "${target_image}" \
    || [[ ! "${previous_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || ! is_digest "${target_digest}"
  then
    fail "runtime config pending state values are invalid"
  fi

  state_image="$(read_state_value APPLICATION_IMAGE)"
  state_digest="$(read_state_value RUNTIME_CONFIG_DIGEST)"
  state_compose_sha="$(read_state_value RUNTIME_CONFIG_COMPOSE_SHA256)"
  state_previous_image="$(read_state_value PREVIOUS_APPLICATION_IMAGE)"
  state_previous_digest="$(read_state_value PREVIOUS_RUNTIME_CONFIG_DIGEST)"

  if [[ "${state_image}" == "${target_image}" && "${state_digest}" == "${target_digest}" ]]; then
    if [[ "${previous_image}" != "${target_image}" ]] \
      || [[ "${previous_digest}" != "${target_digest}" ]]
    then
      if [[ "${state_previous_image}" != "${previous_image}" ]] \
        || [[ "${state_previous_digest}" != "${previous_digest}" ]]
      then
        fail "completed target predecessor does not match pending state"
      fi
    fi
    recovery_release="$(
      validate_verified_release "${target_digest}" "${state_compose_sha}"
    )"
    if [[ "$(read_env_value PORTFOLIO_IMAGE)" != "${target_image}" ]]; then
      fail "application image environment does not match completed target state"
    fi

    recovery_compose="${recovery_release}/compose.yaml"
    validate_compose_contract "${recovery_compose}" "${target_image}"
    running_services="$(
      compose_with "${recovery_compose}" ps --status running --services
    )"
    if [[ "${running_services}" != portfolio ]]; then
      fail "completed Portfolio target service is not running"
    fi
    health_status="$(
      compose_with "${recovery_compose}" ps --format json portfolio \
        | "${PYTHON_BIN}" -c '
import json
import sys

value = json.load(sys.stdin)
entry = value[0] if isinstance(value, list) else value
print(entry.get("Health", ""))
'
    )"
    if [[ "${health_status}" != healthy ]]; then
      fail "completed Portfolio target service is not healthy"
    fi

    expected_current="releases/$("/usr/bin/basename" "${recovery_release}")"
    if [[ ! -L "${RUNTIME_CONFIG_CURRENT}" ]] \
      || [[ "$(/usr/bin/readlink "${RUNTIME_CONFIG_CURRENT}")" != "${expected_current}" ]]
    then
      replace_current_link "${recovery_release}"
    fi
    /bin/rm -f -- "${RUNTIME_CONFIG_PENDING}"
    printf 'Completed Portfolio runtime config transaction finalized: %s\n' "${target_image}"
    return 0
  fi

  if [[ -z "${previous_image}" ]]; then
    if [[ -n "${state_image}" || "${previous_digest}" != "${ZERO_DIGEST}" ]]; then
      fail "bootstrap recovery state is inconsistent"
    fi
    write_image_env "${target_image}"
    if ! compose_with "${LEGACY_COMPOSE_FILE}" down; then
      fail "bootstrap recovery could not remove the interrupted target service"
    fi
    write_image_env ""
    /bin/rm -f -- "${RUNTIME_CONFIG_PENDING}"
    printf 'Interrupted Portfolio bootstrap cleared with the app service removed\n'
    return 0
  fi

  if [[ -z "${state_image}" && -z "${state_digest}" && "${previous_digest}" == "${ZERO_DIGEST}" ]]; then
    recovery_compose="${LEGACY_COMPOSE_FILE}"
  else
    if [[ "${state_image}" != "${previous_image}" || "${state_digest}" != "${previous_digest}" ]]; then
      fail "pending transaction does not match the last verified runtime config state"
    fi
    recovery_release="$(
      validate_verified_release "${previous_digest}" "${state_compose_sha}"
    )"
    recovery_compose="${recovery_release}/compose.yaml"
  fi

  validate_compose_contract "${recovery_compose}" "${previous_image}"
  write_image_env "${previous_image}"
  if ! compose_with "${recovery_compose}" up \
    --no-build \
    --remove-orphans \
    --wait \
    --wait-timeout "${HEALTH_TIMEOUT_SECONDS}"
  then
    fail "runtime config recovery could not restore the previous verified pair"
  fi

  /bin/rm -f -- "${RUNTIME_CONFIG_PENDING}"
  printf 'Portfolio runtime config transaction recovered to: %s\n' "${previous_image}"
}

if [[ "${recovery_mode}" == true ]]; then
  recover_pending_transaction
  exit 0
fi

new_image="${IMAGE_REPOSITORY}@${image_digest}"
current_image="$(read_env_value PORTFOLIO_IMAGE)"
if [[ -n "${current_image}" ]] && ! is_approved_image "${current_image}"; then
  fail "current Portfolio image is not an approved immutable reference"
fi
previous_image="${current_image}"

printf '%s' "${registry_token}" \
  | "${DOCKER_BIN}" \
      --config "${docker_config_dir}" \
      login ghcr.io \
      --username "${registry_user}" \
      --password-stdin \
      >/dev/null
logged_in=true
registry_token=

"${DOCKER_BIN}" --config "${docker_config_dir}" pull "${new_image}"

if [[ "${legacy_mode}" == true ]]; then
  candidate_compose="${LEGACY_COMPOSE_FILE}"
else
  actual_app_revision="$(
    "${DOCKER_BIN}" \
      image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
      "${new_image}"
  )"
  if [[ "${actual_app_revision}" != "${revision}" ]]; then
    fail "application image revision label does not match deployment revision"
  fi

  current_config_digest="$(read_state_value RUNTIME_CONFIG_DIGEST)"
  current_config_revision="$(read_state_value RUNTIME_CONFIG_REVISION)"
  current_config_compose_sha256="$(read_state_value RUNTIME_CONFIG_COMPOSE_SHA256)"
  current_state_image="$(read_state_value APPLICATION_IMAGE)"

  if [[ ! -e "${RUNTIME_CONFIG_STATE}" && ! -L "${RUNTIME_CONFIG_STATE}" ]] \
    && [[ -e "${RUNTIME_CONFIG_CURRENT}" || -L "${RUNTIME_CONFIG_CURRENT}" ]]
  then
    fail "runtime config state is missing while the current release pointer exists"
  fi

  if [[ -e "${RUNTIME_CONFIG_STATE}" || -L "${RUNTIME_CONFIG_STATE}" ]]; then
    validate_state_file
    if [[ ! -f "${RUNTIME_CONFIG_STATE}" || -L "${RUNTIME_CONFIG_STATE}" ]] \
      || ! is_digest "${current_config_digest}" \
      || [[ ! "${current_config_revision}" =~ ^[0-9a-f]{40}$ ]] \
      || [[ ! "${current_config_compose_sha256}" =~ ^[0-9a-f]{64}$ ]] \
      || ! is_approved_image "${current_state_image}" \
      || [[ "${current_state_image}" != "${current_image}" ]]
    then
      fail "current runtime config state is invalid"
    fi
    current_release="$(release_dir_for_digest "${current_config_digest}")"
    if [[ ! -d "${current_release}" ]]; then
      fail "current runtime config release is missing"
    fi
    validate_release_files "${current_release}"
    if [[ "$(compose_sha256 "${current_release}/compose.yaml")" != "${current_config_compose_sha256}" ]]; then
      fail "current runtime config release integrity check failed"
    fi
  else
    current_release=
  fi

  if [[ "${config_mode}" == update ]]; then
    candidate_config_digest="${config_digest}"
    candidate_config_revision="${revision}"
    prepare_runtime_release "${config_digest}" "${revision}"
    candidate_release="${prepared_release}"
    candidate_config_compose_sha256="$(
      compose_sha256 "${candidate_release}/compose.yaml"
    )"
  else
    if [[ -z "${current_release}" ]]; then
      fail "keep mode requires an existing verified runtime config state"
    fi
    candidate_config_digest="${current_config_digest}"
    candidate_config_revision="${current_config_revision}"
    candidate_release="${current_release}"
    candidate_config_compose_sha256="${current_config_compose_sha256}"
  fi

  candidate_compose="${candidate_release}/compose.yaml"
fi

validate_compose_contract "${candidate_compose}" "${new_image}"

if [[ "${legacy_mode}" == true ]]; then
  write_image_env "${new_image}"
else
  previous_config_digest="${current_config_digest:-${ZERO_DIGEST}}"
  if is_digest "${previous_config_digest}"; then
    previous_release="$(release_dir_for_digest "${previous_config_digest}")"
    previous_compose="${previous_release}/compose.yaml"
  else
    previous_compose="${LEGACY_COMPOSE_FILE}"
  fi
  write_pending_state \
    "${previous_image}" \
    "${previous_config_digest}" \
    "${new_image}" \
    "${candidate_config_digest}"
  write_image_env "${new_image}"
fi

if compose_with "${candidate_compose}" up \
  --no-build \
  --remove-orphans \
  --wait \
  --wait-timeout "${HEALTH_TIMEOUT_SECONDS}"
then
  if [[ "${legacy_mode}" == false ]]; then
    write_success_state \
      "${new_image}" \
      "${revision}" \
      "${candidate_config_digest}" \
      "${candidate_config_revision}" \
      "${previous_image}" \
      "${previous_config_digest}" \
      "${candidate_release}" \
      "${candidate_config_compose_sha256}"
  fi
  printf 'Portfolio deployment succeeded: %s\n' "${new_image}"
  exit 0
fi

printf 'Portfolio deployment failed: %s\n' "${new_image}" >&2
compose_with "${candidate_compose}" logs --tail 100 portfolio >&2 || true

if [[ -n "${previous_image}" ]]; then
  printf 'Rolling back to previous image and runtime config\n' >&2
  write_image_env "${previous_image}"
  if [[ "${legacy_mode}" == true ]]; then
    previous_compose="${LEGACY_COMPOSE_FILE}"
  fi

  if compose_with "${previous_compose}" up \
    --no-build \
    --remove-orphans \
    --wait \
    --wait-timeout "${HEALTH_TIMEOUT_SECONDS}"
  then
    if [[ "${legacy_mode}" == false ]]; then
      /bin/rm -f -- "${RUNTIME_CONFIG_PENDING}"
    fi
    printf 'Portfolio rollback succeeded: %s\n' "${previous_image}" >&2
  else
    printf 'Portfolio rollback failed: %s\n' "${previous_image}" >&2
    compose_with "${previous_compose}" logs --tail 100 portfolio >&2 || true
  fi
else
  printf 'No previous immutable image exists; removing failed first deployment\n' >&2
  write_image_env "${new_image}"
  if compose_with "${candidate_compose}" down; then
    write_image_env "${current_image}"
    if [[ "${legacy_mode}" == false ]]; then
      /bin/rm -f -- "${RUNTIME_CONFIG_PENDING}"
    fi
  else
    printf 'Portfolio bootstrap teardown failed; pending transaction retained\n' >&2
  fi
fi

exit 1
