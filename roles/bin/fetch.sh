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

repos=$(gh api "/orgs/$org/repos?per_page=100" --paginate \
  --jq '[.[] | select(.archived | not) | {name, visibility, default_branch, pushed_at}]')
jq -n --arg o "$org" --argjson r "$repos" \
  '{mode: "org", org: $o, repos: $r}' >"$out/context.json"

for name in $(jq -r '.[].name' <<<"$repos"); do
  gh api "/repos/$org/$name/pulls?state=all&per_page=50" \
    --jq '[.[] | {number, title, user: .user.login, draft, created_at, updated_at, merged_at, head: .head.ref, base: .base.ref}]' \
    >"$out/pulls-$name.json" 2>/dev/null || echo '[]' >"$out/pulls-$name.json"
  gh api "/repos/$org/$name/branches?per_page=100" \
    --jq '[.[] | {name, sha: .commit.sha, protected}]' \
    >"$out/branches-$name.json" 2>/dev/null || echo '[]' >"$out/branches-$name.json"
  gh api "/repos/$org/$name/issues?state=open&per_page=100" \
    --jq '[.[] | select(.pull_request == null) | {number, title, labels: [.labels[].name], created_at, updated_at, comments}]' \
    >"$out/issues-$name.json" 2>/dev/null || echo '[]' >"$out/issues-$name.json"
done

echo "fetch: org mode, $(jq 'length' <<<"$repos") repo(s)" >&2
