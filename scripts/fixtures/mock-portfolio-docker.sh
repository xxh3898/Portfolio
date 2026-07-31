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
    if [[ -n "${FAKE_RUNTIME_SCRIPT:-}" ]]; then
      /bin/mkdir -p "${destination}/scripts"
      if [[ "${FAKE_RUNTIME_SYMLINK:-false}" == true ]]; then
        /bin/ln -s "${FAKE_RUNTIME_SCRIPT}" \
          "${destination}/scripts/deploy-portfolio.sh"
      else
        /bin/cp "${FAKE_RUNTIME_SCRIPT}" \
          "${destination}/scripts/deploy-portfolio.sh"
        /bin/chmod 700 "${destination}/scripts/deploy-portfolio.sh"
      fi
      if [[ "${FAKE_RUNTIME_INVALID_SCRIPT_SYNTAX:-false}" == true ]]; then
        printf 'if\n' >"${destination}/scripts/deploy-portfolio.sh"
        /bin/chmod 700 "${destination}/scripts/deploy-portfolio.sh"
      fi
      if [[ "${FAKE_RUNTIME_INSECURE_SCRIPT_MODE:-false}" == true ]]; then
        /bin/chmod 755 "${destination}/scripts/deploy-portfolio.sh"
      fi
    fi
    if [[ "${FAKE_RUNTIME_EXTRA_FILE:-false}" == true ]]; then
      printf 'unexpected\n' >"${destination}/unexpected.txt"
    fi
    if [[ "${FAKE_RUNTIME_EXTRA_DIR:-false}" == true ]]; then
      /bin/mkdir -p "${destination}/unexpected"
    fi
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
      printf '%s\n' "${FAKE_CONFIG_PROJECT:-portfolio}"
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
    if [[ "${arguments}" == *" config "* ]] \
      && [[ "${FAKE_REQUIRE_NO_ENV_RESOLUTION:-false}" == true ]] \
      && [[ "${arguments}" != *" --no-env-resolution "* ]]
    then
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
      env_file=
      previous_argument=
      for argument in "$@"; do
        if [[ "${previous_argument}" == --env-file ]]; then
          env_file="${argument}"
          break
        fi
        previous_argument="${argument}"
      done
      rendered_image="${FAKE_RENDER_IMAGE:-${PORTFOLIO_IMAGE}}"
      project_name="${FAKE_RENDER_PROJECT_NAME:-portfolio}"
      healthcheck_json='{"test":["CMD","wget","-q","-O","/dev/null","http://127.0.0.1:8080/health"],"interval":"30s","timeout":"5s","start_period":"5s","retries":3}'
      if [[ -n "${FAKE_RENDER_HEALTHCHECK_JSON:-}" ]]; then
        healthcheck_json="${FAKE_RENDER_HEALTHCHECK_JSON}"
      fi
      if [[ "${FAKE_DISABLE_HEALTHCHECK:-false}" == true ]]; then
        healthcheck_json='{"disable":true}'
      fi
      profiles_json='[]'
      if [[ "${FAKE_RENDER_WEB_PROFILE:-false}" == true ]]; then
        profiles_json='["optional"]'
      fi
      restart_policy="${FAKE_RENDER_RESTART_POLICY:-unless-stopped}"
      read_only="${FAKE_RENDER_READ_ONLY:-true}"
      init="${FAKE_RENDER_INIT:-true}"
      pids_limit="${FAKE_RENDER_PIDS_LIMIT:-100}"
      security_opt_json="${FAKE_RENDER_SECURITY_OPT_JSON:-[\"no-new-privileges:true\"]}"
      scale="${FAKE_RENDER_SCALE:-1}"
      deploy_json="${FAKE_RENDER_DEPLOY_JSON:-null}"
      user_override="${FAKE_RENDER_USER_OVERRIDE:-}"
      post_start_json="${FAKE_RENDER_POST_START_JSON:-null}"
      env_file_json="${FAKE_RENDER_ENV_FILE_JSON:-null}"
      volumes_from_json="${FAKE_RENDER_VOLUMES_FROM_JSON:-null}"
      volumes_json="${FAKE_RENDER_VOLUMES_JSON:-null}"
      tmpfs_json="${FAKE_RENDER_TMPFS_JSON:-[\"/tmp:size=64m,mode=1777\"]}"
      ports_json="${FAKE_RENDER_PORTS_JSON:-null}"
      use_api_socket="${FAKE_RENDER_USE_API_SOCKET:-false}"
      device_cgroup_rules_json="${FAKE_RENDER_DEVICE_CGROUP_RULES_JSON:-null}"
      gpus_json="${FAKE_RENDER_GPUS_JSON:-null}"
      pid_mode_json="${FAKE_RENDER_PID_MODE_JSON:-null}"
      cgroup_mode_json="${FAKE_RENDER_CGROUP_MODE_JSON:-null}"
      edge_attachment_json="${FAKE_RENDER_EDGE_ATTACHMENT_JSON:-null}"
      logging_json='{"driver":"json-file","options":{"max-size":"10m","max-file":"3"}}'
      if [[ -n "${FAKE_RENDER_LOGGING_JSON:-}" ]]; then
        logging_json="${FAKE_RENDER_LOGGING_JSON}"
      fi
      environment_json="${FAKE_RENDER_ENVIRONMENT_JSON:-null}"
      privileged=false
      if [[ "${FAKE_RENDER_PRIVILEGED_FROM_ENV:-false}" == true ]] \
        && ! /usr/bin/grep -Fxq 'PRIVILEGED=false' "${env_file}"
      then
        privileged=true
      fi
      printf \
        '{"name":"%s","services":{"portfolio":{"image":"%s","restart":"%s","read_only":%s,"init":%s,"pids_limit":%s,"security_opt":%s,"user":"%s","privileged":%s,"scale":%s,"deploy":%s,"profiles":%s,"post_start":%s,"env_file":%s,"volumes_from":%s,"volumes":%s,"tmpfs":%s,"ports":%s,"use_api_socket":%s,"device_cgroup_rules":%s,"gpus":%s,"pid":%s,"cgroup":%s,"logging":%s,"environment":%s,"networks":{"edge":%s},"healthcheck":%s}},"networks":{"edge":{"external":true,"name":"edge"}}}\n' \
        "${project_name}" \
        "${rendered_image}" \
        "${restart_policy}" \
        "${read_only}" \
        "${init}" \
        "${pids_limit}" \
        "${security_opt_json}" \
        "${user_override}" \
        "${privileged}" \
        "${scale}" \
        "${deploy_json}" \
        "${profiles_json}" \
        "${post_start_json}" \
        "${env_file_json}" \
        "${volumes_from_json}" \
        "${volumes_json}" \
        "${tmpfs_json}" \
        "${ports_json}" \
        "${use_api_socket}" \
        "${device_cgroup_rules_json}" \
        "${gpus_json}" \
        "${pid_mode_json}" \
        "${cgroup_mode_json}" \
        "${logging_json}" \
        "${environment_json}" \
        "${edge_attachment_json}" \
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
