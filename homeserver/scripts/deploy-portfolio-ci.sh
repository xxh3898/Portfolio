#!/bin/bash

set -Eeuo pipefail

readonly DEPLOY_SCRIPT=/Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh

original_command="${SSH_ORIGINAL_COMMAND:-}"

if [[ ! "${original_command}" =~ ^deploy-portfolio[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
  printf 'Only deploy-portfolio <image-digest> <registry-user> is allowed\n' >&2
  exit 64
fi

exec "${DEPLOY_SCRIPT}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
