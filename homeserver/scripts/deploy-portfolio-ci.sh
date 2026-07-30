#!/bin/bash

set -Eeuo pipefail

readonly DEPLOY_SCRIPT=/Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh

original_command="${SSH_ORIGINAL_COMMAND:-}"

if [[ "${original_command}" =~ ^deploy-portfolio[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  exec "${DEPLOY_SCRIPT}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
fi

if [[ "${original_command}" =~ ^deploy-portfolio-v2[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([0-9a-f]{40})[[:space:]]keep[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  exec \
    "${DEPLOY_SCRIPT}" \
    "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}" \
    keep \
    "${BASH_REMATCH[3]}"
fi

if [[ "${original_command}" =~ ^deploy-portfolio-v2[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([0-9a-f]{40})[[:space:]]update[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  exec \
    "${DEPLOY_SCRIPT}" \
    "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}" \
    update \
    "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}"
fi

printf '%s\n' \
  'Only deploy-portfolio or strictly formatted deploy-portfolio-v2 commands are allowed' \
  >&2
exit 64
