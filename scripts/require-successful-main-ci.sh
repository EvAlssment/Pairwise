#!/usr/bin/env bash
set -euo pipefail

commit=${1:-}
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Usage: require-successful-main-ci.sh FULL_40_CHARACTER_COMMIT_SHA' >&2
  exit 2
}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

runs=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow tests.yml \
  --branch main --commit "$commit" --limit 20 \
  --json event,status,conclusion)
push_run=$(jq -c '[.[] | select(.event == "push")][0] // empty' <<< "$runs")
if [[ -z "$push_run" ]]; then
  echo 'No push CI run exists for this exact main commit; wait for CI then dispatch again.' >&2
  exit 1
fi

status=$(jq -r '.status' <<< "$push_run")
conclusion=$(jq -r '.conclusion // empty' <<< "$push_run")
if [[ "$status" != completed || "$conclusion" != success ]]; then
  echo "Push CI for $commit is $status/$conclusion; deployment requires completed success." >&2
  exit 1
fi

echo "Push CI passed for $commit."
