#!/bin/bash

set -Eeuo pipefail

readonly PROJECT_ROOT="$(
  CDPATH= cd -- "$(dirname -- "$0")/.." && pwd
)"
readonly DETECT_SCRIPT="${PROJECT_ROOT}/scripts/detect-runtime-config-change.sh"
readonly ZERO_SHA=0000000000000000000000000000000000000000

test_root="$(
  /usr/bin/mktemp -d "${TMPDIR:-/tmp}/portfolio-runtime-detect-test.XXXXXX"
)"

cleanup() {
  if [[ "$(/usr/bin/basename "${test_root}")" == portfolio-runtime-detect-test.* ]]; then
    /bin/rm -rf -- "${test_root}"
  fi
}

trap cleanup EXIT INT TERM

git -C "${test_root}" init --quiet
git -C "${test_root}" config user.email test@example.invalid
git -C "${test_root}" config user.name 'Portfolio Test'

/bin/mkdir -p "${test_root}/homeserver/scripts"
printf 'deny-all\n' >"${test_root}/.dockerignore"
printf 'services: {}\n' >"${test_root}/homeserver/compose.yaml"
printf 'FROM scratch\n' >"${test_root}/homeserver/runtime-config.Dockerfile"
printf '#!/bin/bash\nexit 0\n' \
  >"${test_root}/homeserver/scripts/deploy-portfolio.sh"
printf '<!doctype html>\n' >"${test_root}/index.html"
git -C "${test_root}" add .
git -C "${test_root}" commit --quiet -m base

assert_mode() {
  local before_sha="$1"
  local after_sha="$2"
  local force_sync="$3"
  local expected="$4"
  local actual

  actual="$(
    CDPATH= cd -- "${test_root}"
    "${DETECT_SCRIPT}" \
      "${before_sha}" \
      "${after_sha}" \
      "${force_sync}"
  )"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Runtime config detector mismatch: expected=%s actual=%s\n' \
      "${expected}" \
      "${actual}" \
      >&2
    exit 1
  fi
}

previous_sha="$(git -C "${test_root}" rev-parse HEAD)"

for runtime_path in \
  .dockerignore \
  homeserver/compose.yaml \
  homeserver/runtime-config.Dockerfile \
  homeserver/scripts/deploy-portfolio.sh
do
  printf '\nchange\n' >>"${test_root}/${runtime_path}"
  git -C "${test_root}" add "${runtime_path}"
  git -C "${test_root}" commit --quiet -m "change ${runtime_path}"
  current_sha="$(git -C "${test_root}" rev-parse HEAD)"
  assert_mode "${previous_sha}" "${current_sha}" false update
  previous_sha="${current_sha}"
done

printf '<main>application only</main>\n' >>"${test_root}/index.html"
git -C "${test_root}" add index.html
git -C "${test_root}" commit --quiet -m 'change application only'
current_sha="$(git -C "${test_root}" rev-parse HEAD)"
assert_mode "${previous_sha}" "${current_sha}" false keep
assert_mode "${current_sha}" "${current_sha}" false keep
assert_mode "${ZERO_SHA}" "${current_sha}" false update
assert_mode "${current_sha}" "${current_sha}" true update

printf 'Portfolio runtime config detector tests passed\n'
