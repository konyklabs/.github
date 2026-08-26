#!/usr/bin/env bash
# Decide, before spending anything, whether the review action will be allowed
# to run at all.
#
# claude-code-action refuses to mint its token when the workflow invoking it
# differs from the copy on the repository's default branch. That is the
# anti-tamper rule: a pull request must not be able to review itself into main
# by editing the workflow that reviews it.
#
# The action reports this internally but does not expose it as an action output,
# so the condition is computed here rather than inferred from an empty result.
# Two reasons that is better than reacting after the fact:
#
#   1. A wasted model run is avoided. Without this, triage pays for an Opus call
#      whose token is then refused.
#   2. The failure can be described accurately. "Re-run, this is not a
#      rejection" is right for a reviewer that died mid-flight and wrong here,
#      where re-running can never succeed and only merging will.
#
# Writes `skip=true|false` to $GITHUB_OUTPUT.
set -euo pipefail

out=${GITHUB_OUTPUT:-/dev/stdout}

# github.workflow_ref looks like
#   owner/repo/.github/workflows/pr-review.yml@refs/pull/10/merge
ref=${WORKFLOW_REF:?}
path=${ref%@*}
path=${path#"${REPO:?}/"}

emit() { echo "skip=$1" >>"$out"; echo "check-caller: skip=$1 ($2)" >&2; }

if [ ! -f "$path" ]; then
  # Nothing checked out to compare against; let the action decide rather than
  # guess, and fail in its own words if it refuses.
  emit false "caller $path not present in the checkout"
  exit 0
fi

base=$(gh api "repos/$REPO" --jq .default_branch)

if ! base_blob=$(gh api "repos/$REPO/contents/$path?ref=$base" --jq '.sha' 2>/dev/null); then
  emit true "caller $path does not exist on $base yet"
  exit 0
fi

head_blob=$(git hash-object "$path")

if [ "$head_blob" = "$base_blob" ]; then
  emit false "caller $path matches $base"
else
  emit true "caller $path differs from $base"
fi
