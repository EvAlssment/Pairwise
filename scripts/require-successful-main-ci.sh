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
  --json databaseId,event,status,conclusion)
push_run=$(jq -c '[.[] | select(.event == "push")][0] // empty' <<< "$runs")
if [[ -z "$push_run" ]]; then
  echo 'No push CI run exists for this exact main commit; wait for API CI then dispatch again.' >&2
  exit 1
fi

status=$(jq -r '.status' <<< "$push_run")
if [[ "$status" != completed ]]; then
  echo "Push CI for $commit is still $status; API deployment requires completed API checks." >&2
  exit 1
fi

run_id=$(jq -r '.databaseId' <<< "$push_run")
jobs=$(gh run view "$run_id" --repo "$GITHUB_REPOSITORY" --json jobs)
for required_job in api-image postgres-integration; do
  job=$(jq -c --arg name "$required_job" '[.jobs[] | select(.name == $name)][0] // empty' <<< "$jobs")
  if [[ -z "$job" ]]; then
    echo "Required API CI job '$required_job' is missing from run $run_id." >&2
    exit 1
  fi
  job_status=$(jq -r '.status' <<< "$job")
  job_conclusion=$(jq -r '.conclusion // empty' <<< "$job")
  if [[ "$job_status" != completed || "$job_conclusion" != success ]]; then
    echo "Required API CI job '$required_job' for $commit is $job_status/$job_conclusion." >&2
    exit 1
  fi
done

echo "API push CI (API unit/race/vet, image smoke, and PostgreSQL integration) passed for $commit."
