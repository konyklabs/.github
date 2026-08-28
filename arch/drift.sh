#!/usr/bin/env bash
# Check the model in arch/model against the repositories it claims to describe.
#
# A model that can drift is worse than no model, because it is trusted and
# wrong. `role-heartbeat` already makes this argument about the clock; this is
# the same argument about the architecture. Every claim below is checked against
# a file or an API response, never against a memory of what was true.
#
# Fail-closed, and loud about what it could not check. An earlier draft skipped
# the cross-repo checks silently when no read token was present, which renders
# identically to "the callers all match" — the failure mode fetch.sh already
# documents. A skipped check is printed as SKIP and named in the summary.
#
# Reads:
#   ORG              default konyklabs
#   ROLE_READ_TOKEN  optional. Without it the cross-repo checks SKIP, loudly.
#   LOCAL_REPOS      optional. A directory holding sibling checkouts, used
#                    instead of the API when present (how this runs on a laptop).
#
# Exit codes:
#   0  the model agrees with the repositories
#   1  drift: something in the model is not true, or something true is not in it
#   2  the check could not run at all (bad model, missing tool)
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/.." && pwd)
org=${ORG:-konyklabs}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
skipped=()

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mDRIFT\033[0m %s\n' "$*"; fail=1; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; skipped+=("$1"); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

for t in jq npx; do
  command -v "$t" >/dev/null || { echo "arch/drift.sh needs $t" >&2; exit 2; }
done

# ---------------------------------------------------------------- the model
model=$work/model.json
if ! npx --yes likec4@latest export json "$here/model" -o "$model" >"$work/export.log" 2>&1; then
  sed 's/\x1b\[[0-9;]*m//g' "$work/export.log" >&2
  echo "arch/drift.sh: the model does not export; fix it before checking drift" >&2
  exit 2
fi

# title -> id, for every element of a kind
ids_of_kind() { jq -r --arg k "$1" '.elements | to_entries[] | select(.value.kind == $k) | .key' "$model"; }
titles_of_kind() { jq -r --arg k "$1" '.elements | to_entries[] | select(.value.kind == $k) | .value.title' "$model"; }
id_for_title() { jq -r --arg k "$1" --arg t "$2" '.elements | to_entries[] | select(.value.kind == $k and .value.title == $t) | .key' "$model"; }
# Only `calls` edges. A `governs` edge into a reusable workflow (registry.json
# bounding role-job) is a real relationship and not a caller, and counting it
# as one made the check report drift against itself.
calls_to() { jq -r --arg t "$1" '.relations | to_entries[] | select(.value.target.model == $t and .value.kind == "calls") | .value.source.model' "$model"; }

# Set difference, reported both ways. $1 label, $2 file-of-reality, $3 file-of-model
compare() {
  local what=$1 real=$2 claimed=$3 m
  while read -r m; do [ -n "$m" ] && bad "$what: '$m' exists but the model does not have it"; done \
    < <(comm -23 <(sort -u "$real") <(sort -u "$claimed"))
  while read -r m; do [ -n "$m" ] && bad "$what: the model claims '$m', which does not exist"; done \
    < <(comm -13 <(sort -u "$real") <(sort -u "$claimed"))
  if diff -q <(sort -u "$real") <(sort -u "$claimed") >/dev/null; then
    ok "$what: $(wc -l <"$real" | tr -d ' ') items, all accounted for"
  fi
}

say "arch/drift.sh — model in $here/model, org $org"

# ------------------------------------------------------------- 1. repositories
head_ "1. Repositories"
if gh repo list "$org" --limit 100 --json name -q '.[].name' >"$work/repos.real" 2>"$work/repos.err"; then
  titles_of_kind repo >"$work/repos.model"
  compare "repository" "$work/repos.real" "$work/repos.model"
else
  skip "repositories — gh repo list failed: $(tr -d '\n' <"$work/repos.err" | cut -c1-120)"
fi

# -------------------------------------------------- 2. reusable workflows here
head_ "2. Reusable workflows in $org/.github"
grep -l 'workflow_call:' "$repo_root"/.github/workflows/*.yml 2>/dev/null \
  | xargs -n1 basename >"$work/reusable.real"
titles_of_kind reusable >"$work/reusable.model"
compare "reusable workflow" "$work/reusable.real" "$work/reusable.model"

# --------------------------------------------------------- 3. review gate lenses
head_ "3. Review gate lenses (review/matrix.json)"
jq -r '.lenses[].id' "$repo_root/review/matrix.json" | sed 's/^/lens: /' >"$work/lenses.real"
titles_of_kind agent | grep '^lens: ' >"$work/lenses.model" || true
compare "review lens" "$work/lenses.real" "$work/lenses.model"

# ------------------------------------------------------------ 4. role charters
head_ "4. Role charters (roles/agents/)"
ls "$repo_root"/roles/agents/*.md | xargs -n1 basename | sed 's/\.md$//' | grep -v '^_' >"$work/roles.real"
for r in $(cat "$work/roles.real"); do id_for_title agent "$r"; done | grep . >"$work/roles.model.ids" || true
titles_of_kind agent | grep -Fx -f "$work/roles.real" >"$work/roles.model" || true
compare "role charter" "$work/roles.real" "$work/roles.model"

# ----------------------------------------------- 5. the clock: every job has a role
head_ "5. The clock (roles/registry.json)"
jq -r '.jobs[] | "\(.role) \(.id)"' "$repo_root/roles/registry.json" >"$work/jobs.real"
propose_id=$(jq -r '.elements | to_entries[] | select(.value.kind=="job" and .value.title=="propose") | .key' "$model")
if [ -z "$propose_id" ]; then
  bad "the clock: the model has no 'propose' job, so no charter can be attached to one"
else
  while read -r role job; do
    rid=$(id_for_title agent "$role")
    if [ -z "$rid" ]; then
      bad "the clock: registry job '$job' names role '$role', which the model does not have"
      continue
    fi
    title=$(jq -r --arg s "$rid" --arg t "$propose_id" \
      '.relations | to_entries[] | select(.value.source.model==$s and .value.target.model==$t) | .value.title // ""' "$model")
    if [ -z "$title" ]; then
      bad "the clock: '$role' has no charter edge into propose, so job '$job' is unattributed"
    elif ! printf '%s' "$title" | grep -q -- "$job"; then
      bad "the clock: '$role' runs job '$job', which its charter edge does not list — edge says: $title"
    else
      ok "the clock: $job <- $role"
    fi
  done <"$work/jobs.real"
fi

# ------------------------------------------------ 6. callers of shared workflows
head_ "6. Callers of the shared workflows"
fetch_workflows() { # $1 repo name -> prints workflow file contents, or returns 1
  local r=$1
  if [ -n "${LOCAL_REPOS:-}" ] && [ -d "$LOCAL_REPOS/$r" ]; then
    cat "$LOCAL_REPOS/$r"/.github/workflows/*.yml 2>/dev/null
    return 0   # present but workflow-less is zero callers, not an unread repo
  fi
  [ -n "${ROLE_READ_TOKEN:-}" ] || return 1
  GH_TOKEN=$ROLE_READ_TOKEN gh api "repos/$org/$r/contents/.github/workflows" -q '.[].path' 2>/dev/null \
    | while read -r p; do GH_TOKEN=$ROLE_READ_TOKEN gh api "repos/$org/$r/contents/$p" -q '.content' | base64 -d; done
}

: >"$work/calls.real"
: >"$work/calls.unchecked"
while read -r repo_title; do
  rid=$(id_for_title repo "$repo_title")
  if [ "$repo_title" = ".github" ]; then
    cat "$repo_root"/.github/workflows/*.yml >"$work/wf.txt"
  elif ! fetch_workflows "$repo_title" >"$work/wf.txt" 2>/dev/null; then
    echo "$repo_title" >>"$work/calls.unchecked"; continue
  fi
  grep -o "$org/\.github/\.github/workflows/[a-z-]*\.yml" "$work/wf.txt" \
    | sed "s|.*/||" | sort -u | sed "s|^|$rid |" >>"$work/calls.real"
done < <(titles_of_kind repo)

if [ -s "$work/calls.unchecked" ]; then
  skip "callers — could not read workflows for: $(tr '\n' ' ' <"$work/calls.unchecked")"
fi

# model side: every `calls`-shaped edge into a reusable, attributed to its repo
: >"$work/calls.model"
while read -r wf_id; do
  wf_title=$(jq -r --arg i "$wf_id" '.elements[$i].title' "$model")
  while read -r src; do
    [ -n "$src" ] || continue
    # attribute the edge to the repo the source lives in: konyklabs.<repo>[...]
    printf '%s %s\n' "$(printf '%s' "$src" | cut -d. -f1-2)" "$wf_title"
  done < <(calls_to "$wf_id")
done < <(ids_of_kind reusable) >"$work/calls.model"

# only compare repos we could actually read
if [ -s "$work/calls.unchecked" ]; then
  while read -r u; do
    uid=$(id_for_title repo "$u")
    grep -v "^$uid " "$work/calls.model" >"$work/calls.model.f" && mv "$work/calls.model.f" "$work/calls.model"
  done <"$work/calls.unchecked"
fi
compare "caller edge" "$work/calls.real" "$work/calls.model"

# ------------------------------------------------------------------- summary
head_ "Summary"
if [ ${#skipped[@]} -gt 0 ]; then
  say "  ${#skipped[@]} check(s) SKIPPED — this run did not verify everything:"
  for s in "${skipped[@]}"; do say "    - $s"; done
fi
if [ "$fail" -eq 0 ]; then
  say "  The model agrees with the repositories."
else
  say "  DRIFT. The model and the repositories disagree; one of them is wrong."
fi
exit "$fail"
