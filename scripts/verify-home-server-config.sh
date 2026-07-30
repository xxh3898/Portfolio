#!/bin/bash

set -Eeuo pipefail

PROJECT_ROOT="${1:-$(
  CDPATH= cd -- "$(dirname -- "$0")/.." && pwd
)}"
COMPOSE_FILE="${PROJECT_ROOT}/homeserver/compose.yaml"
RUNTIME_CONFIG_DOCKERFILE="${PROJECT_ROOT}/homeserver/runtime-config.Dockerfile"
DEPLOY_SCRIPT="${PROJECT_ROOT}/homeserver/scripts/deploy-portfolio.sh"
CI_WRAPPER="${PROJECT_ROOT}/homeserver/scripts/deploy-portfolio-ci.sh"
DETECT_SCRIPT="${PROJECT_ROOT}/scripts/detect-runtime-config-change.sh"
DEPLOY_TEST="${PROJECT_ROOT}/scripts/test-deploy-portfolio.sh"
DEPLOY_WORKFLOW="${PROJECT_ROOT}/.github/workflows/deploy.yml"
IMAGE_REPOSITORY=ghcr.io/xxh3898/portfolio
DUMMY_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
OLD_SHA=1111111111111111111111111111111111111111
ZERO_SHA=0000000000000000000000000000000000000000
ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
CURRENT_SHA="$(git -C "${PROJECT_ROOT}" rev-parse HEAD)"

fail() {
  printf '홈서버 설정 검증 실패: %s\n' "$1" >&2
  exit 1
}

assert_exit_64() {
  local description="$1"
  shift
  local exit_code

  set +e
  "$@" >/dev/null 2>&1
  exit_code="$?"
  set -e

  if [[ "${exit_code}" -ne 64 ]]; then
    fail "${description}: expected=64 actual=${exit_code}"
  fi
}

for required_file in \
  "${COMPOSE_FILE}" \
  "${RUNTIME_CONFIG_DOCKERFILE}" \
  "${DEPLOY_SCRIPT}" \
  "${CI_WRAPPER}" \
  "${DETECT_SCRIPT}" \
  "${DEPLOY_TEST}" \
  "${DEPLOY_WORKFLOW}"
do
  if [[ ! -f "${required_file}" ]]; then
    fail "필수 파일이 없습니다: ${required_file#"${PROJECT_ROOT}/"}"
  fi
done

/bin/bash -n \
  "${DEPLOY_SCRIPT}" \
  "${CI_WRAPPER}" \
  "${DETECT_SCRIPT}" \
  "${DEPLOY_TEST}"

assert_exit_64 \
  "배포 스크립트가 인자 누락을 거부해야 합니다" \
  /bin/bash "${DEPLOY_SCRIPT}"
assert_exit_64 \
  "배포 스크립트가 이전 SHA 입력을 거부해야 합니다" \
  /bin/bash "${DEPLOY_SCRIPT}" "${OLD_SHA}" test-user
assert_exit_64 \
  "배포 스크립트가 all-zero digest를 거부해야 합니다" \
  /bin/bash "${DEPLOY_SCRIPT}" "${ZERO_DIGEST}" test-user
assert_exit_64 \
  "CI wrapper가 빈 명령을 거부해야 합니다" \
  /usr/bin/env SSH_ORIGINAL_COMMAND= /bin/bash "${CI_WRAPPER}"
assert_exit_64 \
  "CI wrapper가 이전 SHA 명령을 거부해야 합니다" \
  /usr/bin/env \
    SSH_ORIGINAL_COMMAND="deploy-portfolio ${OLD_SHA} test-user" \
    /bin/bash "${CI_WRAPPER}"
assert_exit_64 \
  "CI wrapper가 update digest 누락을 거부해야 합니다" \
  /usr/bin/env \
    SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${DUMMY_DIGEST} ${OLD_SHA} update test-user" \
    /bin/bash "${CI_WRAPPER}"
assert_exit_64 \
  "CI wrapper가 shell fragment를 거부해야 합니다" \
  /usr/bin/env \
    SSH_ORIGINAL_COMMAND="deploy-portfolio-v2 ${DUMMY_DIGEST} ${OLD_SHA} keep test-user; id" \
    /bin/bash "${CI_WRAPPER}"

if [[ "$("${DETECT_SCRIPT}" "${CURRENT_SHA}" "${CURRENT_SHA}" false)" != keep ]]; then
  fail "동일 revision은 runtime config keep으로 판정해야 합니다"
fi

if [[ "$("${DETECT_SCRIPT}" "${ZERO_SHA}" "${OLD_SHA}" false)" != update ]]; then
  fail "최초 배포는 runtime config update로 판정해야 합니다"
fi

if [[ "$("${DETECT_SCRIPT}" "${CURRENT_SHA}" "${CURRENT_SHA}" true)" != update ]]; then
  fail "강제 동기화는 runtime config update로 판정해야 합니다"
fi

if ! command -v docker >/dev/null 2>&1; then
  fail "Docker CLI를 찾을 수 없습니다"
fi

PORTFOLIO_IMAGE="${IMAGE_REPOSITORY}@${DUMMY_DIGEST}" \
  docker compose \
    --project-directory "${PROJECT_ROOT}/homeserver" \
    --file "${COMPOSE_FILE}" \
    config \
    --quiet

resolved_image="$(
  PORTFOLIO_IMAGE="${IMAGE_REPOSITORY}@${DUMMY_DIGEST}" \
    docker compose \
      --project-directory "${PROJECT_ROOT}/homeserver" \
      --file "${COMPOSE_FILE}" \
      config \
      --images
)"

if [[ "${resolved_image}" != "${IMAGE_REPOSITORY}@${DUMMY_DIGEST}" ]]; then
  fail "Compose image가 exact digest로 해석되지 않습니다: ${resolved_image}"
fi

secret_candidate="$(
  /usr/bin/find "${PROJECT_ROOT}/homeserver" -type f \
    \( \
      -name '.env' \
      -o -name '*.key' \
      -o -name '*.pem' \
      -o -name 'known_hosts' \
      -o -name 'id_*' \
    \) \
    -print
)"

if [[ -n "${secret_candidate}" ]]; then
  fail "homeserver 디렉터리에 비밀 파일 후보가 있습니다: ${secret_candidate#"${PROJECT_ROOT}/"}"
fi

if /usr/bin/grep -Fq "${IMAGE_REPOSITORY}:main" \
  "${DEPLOY_WORKFLOW}" \
  "${DEPLOY_SCRIPT}" \
  "${CI_WRAPPER}"
then
  fail "mutable main tag가 배포 계약에 남아 있습니다"
fi

if ! /usr/bin/grep -Fq 'needs.publish.outputs.image_digest' "${DEPLOY_WORKFLOW}"; then
  fail "publish digest가 deploy job에 연결되지 않았습니다"
fi

if ! /usr/bin/grep -Fq 'runtime_config_mode' "${DEPLOY_WORKFLOW}" \
  || ! /usr/bin/grep -Fq 'runtime_config_digest' "${DEPLOY_WORKFLOW}"
then
  fail "runtime config mode와 digest가 deploy job에 연결되지 않았습니다"
fi

"${DEPLOY_TEST}"

printf '홈서버 설정 검증 통과\n'
printf -- '- Compose image: %s@%s\n' "${IMAGE_REPOSITORY}" "${DUMMY_DIGEST}"
printf -- '- 배포 입력: application digest + runtime config keep/update\n'
