#!/bin/bash

set -Eeuo pipefail

readonly DOCKER_BIN=/usr/local/bin/docker
readonly APP_DIR=/Users/homeserver/Server/apps/portfolio
readonly COMPOSE_FILE="${APP_DIR}/compose.yaml"
readonly ENV_FILE="${APP_DIR}/.env"
readonly IMAGE_REPOSITORY=ghcr.io/xxh3898/portfolio
readonly ZERO_SHA=0000000000000000000000000000000000000000
readonly ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
readonly HEALTH_TIMEOUT_SECONDS=60

usage() {
  printf 'Usage: deploy-portfolio.sh <image-digest> <registry-user>\n' >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 64
fi

image_digest="$1"
registry_user="$2"

if [[ ! "${image_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || [[ "${image_digest}" == "${ZERO_DIGEST}" ]]
then
  printf 'Image digest must use sha256 followed by 64 lowercase hexadecimal characters\n' >&2
  exit 64
fi

if [[ ! "${registry_user}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  printf 'Registry user contains unsupported characters\n' >&2
  exit 64
fi

if [[ ! -x "${DOCKER_BIN}" ]]; then
  printf 'Docker CLI is not executable: %s\n' "${DOCKER_BIN}" >&2
  exit 69
fi

if [[ ! -f "${COMPOSE_FILE}" || ! -f "${ENV_FILE}" ]]; then
  printf 'Portfolio Compose configuration is incomplete\n' >&2
  exit 66
fi

registry_token="$(/bin/cat)"

if [[ -z "${registry_token}" ]]; then
  printf 'GHCR token must not be empty\n' >&2
  exit 64
fi

umask 077

docker_config_dir="$(
  /usr/bin/mktemp -d "${TMPDIR:-/tmp}/portfolio-docker-config.XXXXXX"
)"
env_temp=
logged_in=false

# ShellCheck cannot infer that trap invokes this cleanup function.
# shellcheck disable=SC2329
cleanup() {
  registry_token=

  if [[ -n "${env_temp}" && -e "${env_temp}" ]]; then
    /bin/rm -f -- "${env_temp}"
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

write_image_env() {
  local image="$1"

  env_temp="$(/usr/bin/mktemp "${APP_DIR}/.env.tmp.XXXXXX")"
  printf 'PORTFOLIO_IMAGE=%s\n' "${image}" >"${env_temp}"
  /bin/chmod 600 "${env_temp}"
  /bin/mv -f -- "${env_temp}" "${ENV_FILE}"
  env_temp=
}

compose() {
  "${DOCKER_BIN}" \
    compose \
    --project-directory "${APP_DIR}" \
    --env-file "${ENV_FILE}" \
    --file "${COMPOSE_FILE}" \
    "$@"
}

is_sha_image() {
  local image="$1"
  local image_sha

  image_sha="${image#"${IMAGE_REPOSITORY}:"}"

  [[ "${image}" == "${IMAGE_REPOSITORY}:${image_sha}" ]] \
    && [[ "${image_sha}" =~ ^[0-9a-fA-F]{40}$ ]] \
    && [[ "${image_sha}" != "${ZERO_SHA}" ]]
}

is_digest_image() {
  local image="$1"
  local digest

  digest="${image#"${IMAGE_REPOSITORY}@"}"

  [[ "${image}" == "${IMAGE_REPOSITORY}@${digest}" ]] \
    && [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "${digest}" != "${ZERO_DIGEST}" ]]
}

new_image="${IMAGE_REPOSITORY}@${image_digest}"
current_image="$(
  /usr/bin/sed -n 's/^PORTFOLIO_IMAGE=//p' "${ENV_FILE}" \
    | /usr/bin/tail -n 1
)"
previous_image=

if is_sha_image "${current_image}" || is_digest_image "${current_image}"; then
  previous_image="${current_image}"
elif [[ -n "${current_image}" ]]; then
  printf 'Current Portfolio image is not an approved immutable reference\n' >&2
  exit 65
fi

printf '%s' "${registry_token}" \
  | "${DOCKER_BIN}" \
      --config "${docker_config_dir}" \
      login ghcr.io \
      --username "${registry_user}" \
      --password-stdin \
      >/dev/null
logged_in=true
registry_token=

"${DOCKER_BIN}" \
  --config "${docker_config_dir}" \
  pull "${new_image}"

PORTFOLIO_IMAGE="${new_image}" \
  "${DOCKER_BIN}" \
    compose \
    --project-directory "${APP_DIR}" \
    --file "${COMPOSE_FILE}" \
    config \
    --quiet

write_image_env "${new_image}"

if compose up \
  --no-build \
  --remove-orphans \
  --wait \
  --wait-timeout "${HEALTH_TIMEOUT_SECONDS}"
then
  printf 'Portfolio deployment succeeded: %s\n' "${new_image}"
  exit 0
fi

printf 'Portfolio deployment failed: %s\n' "${new_image}" >&2
compose logs --tail 100 portfolio >&2 || true

if [[ -n "${previous_image}" ]]; then
  printf 'Rolling back to previous image: %s\n' "${previous_image}" >&2
  write_image_env "${previous_image}"

  if compose up \
    --no-build \
    --remove-orphans \
    --wait \
    --wait-timeout "${HEALTH_TIMEOUT_SECONDS}"
  then
    printf 'Portfolio rollback succeeded: %s\n' "${previous_image}" >&2
  else
    printf 'Portfolio rollback failed: %s\n' "${previous_image}" >&2
    compose logs --tail 100 portfolio >&2 || true
  fi
else
  printf 'No previous immutable image exists; removing failed first deployment\n' >&2
  compose down || true
  write_image_env "${current_image}"
fi

exit 1
