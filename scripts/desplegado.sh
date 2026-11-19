#!/usr/bin/env bash
# Commit del último despliegue exitoso en el environment <amb> (vacío si nunca hubo uno). Requiere GH_TOKEN.
set -euo pipefail
amb="${1:?ambiente}"
for id in $(gh api "repos/$GITHUB_REPOSITORY/deployments?environment=$amb&per_page=50" --jq '.[].id'); do
  if [ "$(gh api "repos/$GITHUB_REPOSITORY/deployments/$id/statuses" --jq '.[0].state')" = success ]; then
    gh api "repos/$GITHUB_REPOSITORY/deployments/$id" --jq .sha
    exit 0
  fi
done
