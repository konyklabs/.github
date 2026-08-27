#!/usr/bin/env bash
# Fetch cross-repo context BEFORE the model runs, so the model never holds the
# credential that fetched it.
#
# This script exists because of a hole this design opened while closing another
# one. delivery-manager and architect read across the org, GITHUB_TOKEN is
# scoped to one repository, and the obvious fix — exporting a PAT as GH_TOKEN in
# the model's job — destroys the property the whole propose/apply split rests
# on. A `permissions:` block bounds GITHUB_TOKEN and nothing else, so a classic
# PAT with `repo` (the only classic scope that grants cross-repo issue reads)
# would have let the model POST a comment directly with `gh api --method POST`,
# bypassing the caps, the allowlist, the evidence rule and the scope binding all
# at once — on po-intake, whose input is text a stranger wrote.
#
# So: data in, credential out. This runs with no model. The model reads JSON
# files and never sees ROLE_READ_TOKEN.
#
# Fail-closed. An earlier revision ended every per-repo call with
# `|| echo '[]'`, which wrote a 403, a secondary rate limit and a 5xx to disk as
# a repository that genuinely has nothing open — and `surveyed.items_read` does
# not catch that, because the other repos still supply a plausible count. A
# weekly report that silently omits a repository is worse than no report, so a
# call that will not succeed after one retry fails the step and the model never
# runs.
#
# Reads $ORG, $ROLE_READ_TOKEN (optional), $OUT (default .roles-context).
set -euo pipefail

org=${ORG:?org}
out=${OUT:-.roles-context}
mkdir -p "$out"

if [ -z "${ROLE_READ_TOKEN:-}" ]; then
  jq -n --arg o "$org" '{mode: "single-repo", org: $o,
    note: "No ROLE_READ_TOKEN configured. Only the calling repository is visible. Say so in surveyed.sources and in unresolved rather than reporting a smaller org."}' \
    >"$out/context.json"
  echo "fetch: single-repo mode, no read token" >&2
  exit 0
fi

export GH_TOKEN=$ROLE_READ_TOKEN

repos=$(gh api "/orgs/$org/repos?per_page=100" --paginate --jq '.[]' \
  | jq -sc '[.[] | select(.archived | not) | {name, visibility, default_branch, pushed_at}]')
jq -n --arg o "$org" --argjson r "$repos" \
  '{mode: "org", org: $o, repos: $r}' >"$out/context.json"

# collect <dest> <path> <jq>  — one retry, then fail loudly. Never writes a
# fallback for a call that failed: an empty file meaning "the call failed" is
# the bug this closes.
#
# collect <dest> <path> <jq>  — one retry, then fail loudly. Never writes a
# fallback for a call that failed: an empty file meaning "the call failed" is
# the bug this closes.
#
# --paginate, always. `per_page=50` with no pagination returned the fifty most
# recently CREATED pull requests, closed ones included, so an old open PR was
# pushed out by newer noise and nothing said a list had been cut off. There is
# no note for that case because there is no longer that case: a list here is
# complete or the fetch fails. `/issues` had the same shape, where
# `select(.pull_request == null)` dropped PRs only after they had spent the page.
#
# `--paginate --jq '.[]'` streams elements across pages; `jq -s` reassembles
# them. `--slurp` cannot be combined with `--jq`, and `--paginate --jq '[...]'`
# emits one array PER PAGE, which is invalid JSON the moment a second page
# exists — a bug that hides until the org outgrows one page.
#
# Two responses are NOT failures, because they are permanent facts about a
# repository rather than transient conditions, and retrying them forever would
# take the whole clock down nightly:
#
#   409 Conflict  /branches on a repository created and never pushed to
#   410 Gone      /issues on a repository with Issues disabled
#
# Those write an empty array AND a note in context.json, so the model can tell
# "empty because the repository is empty" from "empty because a call failed" —
# which is the distinction this whole script exists to preserve.
notes=()

collect() {
  local dest=$1 path=$2 filter=$3 raw
  if ! raw=$(gh api "$path" --paginate --jq '.[]' 2>&1); then
    case "$raw" in
      *"HTTP 409"*|*"Git Repository is empty"*)
        printf '[]' >"$dest"
        notes+=("$(jq -c -n --arg p "$path" '{path: $p, status: 409, meaning: "repository is empty; the empty array is a fact, not a failure"}')")
        return 0 ;;
      *"HTTP 410"*|*"Issues are disabled"*|*"Gone"*)
        printf '[]' >"$dest"
        notes+=("$(jq -c -n --arg p "$path" '{path: $p, status: 410, meaning: "endpoint disabled for this repository; the empty array is a fact, not a failure"}')")
        return 0 ;;
    esac
    sleep "${FETCH_RETRY_SLEEP:-3}"
    if ! raw=$(gh api "$path" --paginate --jq '.[]' 2>&1); then
      echo "::error::fetch failed for $path after one retry: $(head -c 300 <<<"$raw")"
      return 1
    fi
  fi
  if ! jq -sc "$filter" >"$dest" <<<"$raw"; then
    echo "::error::fetch got unparseable output for $path"
    return 1
  fi
}

failed=0
for name in $(jq -r '.[].name' <<<"$repos"); do
  collect "$out/pulls-$name.json" "/repos/$org/$name/pulls?state=all&per_page=100" \
    '[.[] | {number, title, user: .user.login, draft, created_at, updated_at, merged_at, head: .head.ref, base: .base.ref}]' || failed=1
  collect "$out/branches-$name.json" "/repos/$org/$name/branches?per_page=100" \
    '[.[] | {name, sha: .commit.sha, protected}]' || failed=1
  collect "$out/issues-$name.json" "/repos/$org/$name/issues?state=open&per_page=100" \
    '[.[] | select(.pull_request == null) | {number, title, labels: [.labels[].name], created_at, updated_at, comments}]' || failed=1
done

# Notes go into the context the model reads, not only into the step log.
if [ ${#notes[@]} -gt 0 ]; then
  jq --argjson n "$(printf '%s\n' "${notes[@]}" | jq -sc '.')" '. + {notes: $n}' \
    "$out/context.json" >"$out/context.json.tmp" && mv "$out/context.json.tmp" "$out/context.json"
  echo "fetch: ${#notes[@]} endpoint(s) legitimately empty; recorded in context.json" >&2
fi

if [ "$failed" -ne 0 ]; then
  # Deleting the context is deliberate: a half-fetched bundle that a later step
  # might read is exactly the state this guard exists to prevent.
  rm -f "$out"/context.json
  echo "::error::Cross-repo context is incomplete. Failing before the model runs, because a report that silently omits a repository is worse than no report."
  exit 1
fi

echo "fetch: org mode, $(jq 'length' <<<"$repos") repo(s)" >&2
