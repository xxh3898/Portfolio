#!/bin/bash

set -Eeuo pipefail

if [[ "${1:-}" == --config ]]; then
  shift 2
fi

command_name="${1:-}"
shift || true

if [[ -n "${FAKE_DOCKER_LOG:-}" ]]; then
  printf '%s %s\n' "${command_name}" "$*" >>"${FAKE_DOCKER_LOG}"
fi

case "${command_name}" in
  login|logout|pull|rm)
    exit 0
    ;;
  create)
    printf 'mock-runtime-config-container\n'
    ;;
  cp)
    destination="$2"
    if [[ "${FAKE_FAIL_CP:-false}" == true ]]; then
      exit 1
    fi
    /bin/cp "${FAKE_RUNTIME_COMPOSE}" "${destination}/compose.yaml"
    ;;
  image)
    test "$1" = inspect
    shift
    test "$1" = --format
    shift
    format="$1"
    image="$2"
    if [[ "${format}" == *org.opencontainers.image.revision* ]]; then
      case "${image}" in
        *portfolio-runtime-config*)
          printf '%s\n' "${FAKE_CONFIG_REVISION}"
          ;;
        *"${FAKE_APP_DIGEST_ONE}"*)
          printf '%s\n' "${FAKE_APP_REVISION_ONE}"
          ;;
        *"${FAKE_APP_DIGEST_TWO}"*)
          printf '%s\n' "${FAKE_APP_REVISION_TWO}"
          ;;
        *)
          printf '%s\n' "${FAKE_APP_REVISION_THREE:-${FAKE_APP_REVISION_TWO}}"
          ;;
      esac
    elif [[ "${format}" == *io.chochiho.runtime-config.project* ]]; then
      printf 'portfolio\n'
    else
      exit 1
    fi
    ;;
  compose)
    arguments=" $* "
    if [[ "${arguments}" == *" --format json "* ]]; then
      printf '%s\n' \
        '{"services":{"portfolio":{"networks":{"edge":null},"read_only":true,"init":true,"security_opt":["no-new-privileges:true"],"healthcheck":{"test":["CMD","true"]}}},"networks":{"edge":{"external":true,"name":"edge"}}}'
    elif [[ "${arguments}" == *" ps --status running --services "* ]]; then
      printf 'portfolio\n'
    fi
    ;;
  *)
    printf 'Unexpected mock Docker command: %s\n' "${command_name}" >&2
    exit 1
    ;;
esac
