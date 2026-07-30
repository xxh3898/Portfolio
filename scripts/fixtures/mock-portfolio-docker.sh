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
    if [[ "${arguments}" == *" up "* ]] \
      && [[ "${FAKE_FAIL_IF_AMBIENT_IMAGE:-false}" == true ]] \
      && [[ -n "${PORTFOLIO_IMAGE:-}" ]]
    then
      exit 1
    fi
    if [[ "${arguments}" == *" up "* && "${FAKE_FAIL_UP:-false}" == true ]]; then
      exit 1
    fi
    if [[ "${arguments}" == *" down "* && "${FAKE_REQUIRE_NONEMPTY_ENV_ON_DOWN:-false}" == true ]]; then
      env_file=
      previous_argument=
      for argument in "$@"; do
        if [[ "${previous_argument}" == --env-file ]]; then
          env_file="${argument}"
          break
        fi
        previous_argument="${argument}"
      done
      if [[ -z "${env_file}" ]] \
        || ! /usr/bin/grep -Eq '^PORTFOLIO_IMAGE=ghcr\.io/xxh3898/portfolio@sha256:[0-9a-f]{64}$' "${env_file}"
      then
        exit 1
      fi
    fi
    if [[ "${arguments}" == *" ps --format json portfolio "* ]]; then
      printf '[{"Service":"portfolio","Health":"%s"}]\n' \
        "${FAKE_SERVICE_HEALTH:-healthy}"
    elif [[ "${arguments}" == *" --format json "* ]]; then
      rendered_image="${FAKE_RENDER_IMAGE:-${PORTFOLIO_IMAGE}}"
      project_name="${FAKE_RENDER_PROJECT_NAME:-portfolio}"
      healthcheck_json='{"test":["CMD","wget","-q","-O","/dev/null","http://127.0.0.1:8080/health"]}'
      if [[ "${FAKE_DISABLE_HEALTHCHECK:-false}" == true ]]; then
        healthcheck_json='{"disable":true}'
      fi
      profiles_json='[]'
      if [[ "${FAKE_RENDER_WEB_PROFILE:-false}" == true ]]; then
        profiles_json='["optional"]'
      fi
      restart_policy="${FAKE_RENDER_RESTART_POLICY:-unless-stopped}"
      scale="${FAKE_RENDER_SCALE:-1}"
      user_override="${FAKE_RENDER_USER_OVERRIDE:-}"
      tmpfs_json="${FAKE_RENDER_TMPFS_JSON:-[\"/tmp:size=64m,mode=1777\"]}"
      security_opt_json="${FAKE_RENDER_SECURITY_OPT_JSON:-[\"no-new-privileges:true\"]}"
      post_start_json="${FAKE_RENDER_POST_START_JSON:-null}"
      printf \
        '{"name":"%s","services":{"portfolio":{"image":"%s","restart":"%s","user":"%s","scale":%s,"profiles":%s,"post_start":%s,"networks":{"edge":null},"read_only":true,"init":true,"security_opt":%s,"tmpfs":%s,"healthcheck":%s}},"networks":{"edge":{"external":true,"name":"edge"}}}\n' \
        "${project_name}" \
        "${rendered_image}" \
        "${restart_policy}" \
        "${user_override}" \
        "${scale}" \
        "${profiles_json}" \
        "${post_start_json}" \
        "${security_opt_json}" \
        "${tmpfs_json}" \
        "${healthcheck_json}"
    elif [[ "${arguments}" == *" ps --status running --services "* ]]; then
      printf 'portfolio\n'
    fi
    ;;
  *)
    printf 'Unexpected mock Docker command: %s\n' "${command_name}" >&2
    exit 1
    ;;
esac
