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

# The renderer is pinned in arch/package.json, and the pin has to govern what
# actually runs or it is decoration. `likec4@latest` did not: npx resolves an
# explicit tag against the registry and ignores the installed copy, so the JSON
# schema this script's jq queries read, and the bytes the staleness check
# compares, both floated. Installed copy first; otherwise the exact pinned
# version, never `latest`.
likec4() {
  local bin=$here/node_modules/.bin/likec4
  if [ -x "$bin" ]; then
    "$bin" "$@"
  else
    local v
    v=$(jq -r '.devDependencies.likec4' "$here/package.json")
    [ -n "$v" ] && [ "$v" != null ] || { echo "arch/drift.sh: no pinned likec4 version in package.json" >&2; exit 2; }
    npx --yes "likec4@$v" "$@"
  fi
}

# ---------------------------------------------------------------- the model
model=$work/model.json
if ! likec4 export json "$here/model" -o "$model" >"$work/export.log" 2>&1; then
  sed 's/\x1b\[[0-9;]*m//g' "$work/export.log" >&2
  echo "arch/drift.sh: the model does not export; fix it before checking drift" >&2
  exit 2
fi

# title -> id, for every element of a kind
ids_of_kind() { jq -r --arg k "$1" '.elements | to_entries[] | select(.value.kind == $k) | .key' "$model"; }
titles_of_kind() { jq -r --arg k "$1" '.elements | to_entries[] | select(.value.kind == $k) | .value.title' "$model"; }
# Tag-based selection, because the model has to say what a thing IS. Matching on
# the title spelling made check 4 one-way by construction: the model side was
# built by grepping the model's titles for the real filenames, so it was a subset
# of reality for any model content whatsoever, and a charter the model invented
# could never be reported.
titles_of_tag() { jq -r --arg t "$1" '.elements | to_entries[] | select((.value.tags // []) | index($t)) | .value.title' "$model"; }
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
#
# GITHUB_TOKEN is scoped to one repository, so `gh repo list` under it returns
# the org's PUBLIC repositories and nothing else. Treating that as the org is how
# the first CI run of this script reported five private repositories as
# nonexistent — a confident, wrong finding, which is worse than no finding.
#
# So the listing's completeness decides the direction of the check. With
# ROLE_READ_TOKEN it is the org and both directions hold. Without it, only one
# direction is knowable: everything visible must be in the model. The model may
# name repositories this token cannot see, and that is not evidence of anything.
head_ "1. Repositories"
full_org=0
if [ -n "${ROLE_READ_TOKEN:-}" ] \
   && GH_TOKEN=$ROLE_READ_TOKEN gh repo list "$org" --limit 100 --json name -q '.[].name' \
      >"$work/repos.real" 2>"$work/repos.err"; then
  full_org=1
elif ! gh repo list "$org" --limit 100 --json name -q '.[].name' >"$work/repos.real" 2>"$work/repos.err"; then
  skip "repositories — gh repo list failed: $(tr -d '\n' <"$work/repos.err" | cut -c1-120)"
  : >"$work/repos.real"
fi

titles_of_kind repo >"$work/repos.model"
if [ "$full_org" -eq 1 ]; then
  compare "repository" "$work/repos.real" "$work/repos.model"
elif [ -s "$work/repos.real" ]; then
  n_seen=$(wc -l <"$work/repos.real" | tr -d ' ')
  n_model=$(wc -l <"$work/repos.model" | tr -d ' ')
  while read -r m; do
    [ -n "$m" ] && bad "repository: '$m' exists but the model does not have it"
  done < <(comm -23 <(sort -u "$work/repos.real") <(sort -u "$work/repos.model"))
  [ "$fail" -eq 0 ] && ok "repository: all $n_seen visible repositories are in the model"
  if [ "$n_model" -gt "$n_seen" ]; then
    skip "repositories — no ROLE_READ_TOKEN. Only the $n_seen this token can see were checked; the model names $n_model, and the other $((n_model - n_seen)) were neither confirmed nor denied."
  else
    skip "repositories — no ROLE_READ_TOKEN. All $n_seen visible are modelled, but a repository invisible to this token and missing from the model would not have been caught."
  fi
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
titles_of_tag lens >"$work/lenses.model" || true
compare "review lens" "$work/lenses.real" "$work/lenses.model"

# ------------------------------------------------------------ 4. role charters
head_ "4. Role charters (roles/agents/)"
ls "$repo_root"/roles/agents/*.md | xargs -n1 basename | sed 's/\.md$//' | grep -v '^_' >"$work/roles.real"
titles_of_tag charter >"$work/roles.model" || true
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

# ------------------------------------------------- 7. the invariant, as a check
#
# The `trust` view draws the rule; this enforces it. A view is a picture somebody
# has to open, and the review that produced this check made the point exactly:
# a detector that cannot raise its own alarm is not a detector. The rule is that
# nothing with a language model in it writes a durable record directly — the
# unattended lanes hop through a script, the interactive ones through the gate.
# In the model that is one statement: no element tagged #model-in-it may be the
# source of an `applies` edge.
head_ "7. The invariant (no model writes a record directly)"
violations=$(jq -r '
  [ .relations | to_entries[] | .value | select(.kind == "applies") | .source.model ] as $sources
  | .elements | to_entries[]
  | select((.value.tags // []) | index("model-in-it"))
  | select(.key as $k | $sources | index($k))
  | .key' "$model")
if [ -n "$violations" ]; then
  while read -r v; do
    [ -n "$v" ] && bad "invariant: '$v' has a model in it and writes a durable record directly"
  done <<<"$violations"
else
  n_hot=$(jq -r '[.elements | to_entries[] | select((.value.tags // []) | index("model-in-it"))] | length' "$model")
  n_applies=$(jq -r '[.relations | to_entries[] | select(.value.kind == "applies")] | length' "$model")
  ok "invariant: $n_applies write edges, none of them from any of the $n_hot elements with a model in it"
fi

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
