#!/bin/bash

set -Eeuo pipefail

readonly ZERO_SHA=0000000000000000000000000000000000000000

if [[ "$#" -ne 3 ]]; then
  printf 'Usage: detect-runtime-config-change.sh <before-sha> <after-sha> <force-sync>\n' >&2
  exit 64
fi

before_sha="$1"
after_sha="$2"
force_sync="$3"

if [[ ! "${before_sha}" =~ ^[0-9a-fA-F]{40}$ ]] \
  || [[ ! "${after_sha}" =~ ^[0-9a-fA-F]{40}$ ]]
then
  printf 'Git revisions must contain exactly 40 hexadecimal characters\n' >&2
  exit 64
fi

if [[ "${force_sync}" != true && "${force_sync}" != false ]]; then
  printf 'force-sync must be true or false\n' >&2
  exit 64
fi

if [[ "${force_sync}" == true ]] \
  || [[ "${before_sha}" == "${ZERO_SHA}" ]] \
  || ! git cat-file -e "${before_sha}^{commit}" 2>/dev/null
then
  printf 'update\n'
  exit 0
fi

if git diff --quiet \
  "${before_sha}" \
  "${after_sha}" \
  -- \
  .dockerignore \
  homeserver/compose.yaml \
  homeserver/scripts/deploy-portfolio.sh \
  homeserver/runtime-config.Dockerfile
then
  printf 'keep\n'
else
  printf 'update\n'
fi
