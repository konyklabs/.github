#!/usr/bin/env bash
# Dead-man's switch for the org clock (konyklabs/roadmap#12).
#
# There is no receipt store. Every role run's `run-name` is `role/<job-id>`, so
# the Actions run history IS the receipt and this script reads it back. Adding a
# datastore to prove a scheduled job ran would itself be a scheduled job that
# could stop, which is how these things become turtles.
#
# It checks two things, because a clock fails in two ways:
#
#   1. A job in the registry has not run inside its window. Silent failure, the
#      dangerous kind — private repos are exempt from the 60-day scheduled
#      workflow disable, so nothing tells you it stopped.
#   2. The registry's crons and the caller's disagree, in either direction.
#      GitHub cannot read a cron out of a JSON file, so those two lists are
#      duplicated; this check is the price of that duplication being safe. Both
#      directions matter: a registry cron missing from the caller is a job that
#      never fires, and a caller cron missing from the registry is a trigger
#      that fires nothing — a job id renamed in the registry leaves exactly
#      that behind. Crons that legitimately belong to the caller without being
#      jobs (the heartbeat's own) are declared in registry.json `clock.reserved`
#      rather than exempted by being unchecked.
#
# Reads $REPO, $CALLER (default .github/workflows/roles.yml), $GH_TOKEN.
# Optional: $ROLE_STAGE (true = print the issue writes, make none). The switch
# exists because this job holds `issues: write` and D-004 promises every job can
# be dry-run before it is trusted; without it, the first heartbeat invocation
# would open or close a live tracking issue.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
registry="$here/registry.json"
repo=${REPO:?repo}
caller=${CALLER:-.github/workflows/roles.yml}
stage=${ROLE_STAGE:-false}
title="Role clock: scheduled jobs are not running"

gh_do() {
  if [ "$stage" = "true" ]; then
    printf 'STAGED: gh %s\n' "$*" >>"$summary"
    return 0
  fi
  gh "$@"
}

epoch() { # ISO-8601 Z -> epoch seconds. GNU first, then BSD, so this runs on
          # the laptop as well as the runner and stays testable.
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}

secs() { # 36h / 8d / 90m -> seconds
  local w=$1 n=${1%[hdm]} u=${1: -1}
  case "$u" in h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; m) echo $((n * 60)) ;;
    *) echo "::error::Bad window '$w' in registry"; exit 1 ;; esac
}

runs=$(gh api "/repos/$repo/actions/runs?per_page=100" \
  --jq '[.workflow_runs[] | {name: .display_title, at: .created_at, concl: .conclusion, url: .html_url}]')

now=$(date -u +%s)
problems=()
missing=0; checked=0

while read -r entry; do
  id=$(jq -r '.id' <<<"$entry")
  window=$(jq -r '.window' <<<"$entry")
  [ "$window" = "null" ] && continue

  checked=$((checked + 1))
  last=$(jq -c --arg n "role/$id" '[.[] | select(.name == $n)] | sort_by(.at) | last' <<<"$runs")
  if [ "$last" = "null" ]; then
    missing=$((missing + 1))
    problems+=("- \`$id\` — **no run found** in the last 100 runs of \`$repo\`.")
    continue
  fi
  at=$(jq -r '.at' <<<"$last")
  age=$(( now - $(epoch "$at") ))
  limit=$(secs "$window")
  concl=$(jq -r '.concl' <<<"$last")
  url=$(jq -r '.url' <<<"$last")
  if [ "$age" -gt "$limit" ]; then
    problems+=("- \`$id\` — last run $((age / 3600))h ago, window is \`$window\`. [run]($url)")
  elif [ "$concl" != "success" ]; then
    problems+=("- \`$id\` — ran $((age / 3600))h ago but concluded \`$concl\`. [run]($url)")
  fi
done < <(jq -c '.jobs[]' "$registry")

# Every single job missing, while the repository plainly has run history, is one
# fault and not N: the caller is not setting `run-name: role/<job-id>`, which is
# the only receipt this script has. Reporting it per job would bury the cause
# under its own symptoms, and would look identical to a clock that never ran.
if [ "$checked" -gt 0 ] && [ "$missing" -eq "$checked" ] && [ "$(jq 'length' <<<"$runs")" -gt 0 ]; then
  problems=("- No run in \`$repo\` has a display title matching any registry job id. The caller is almost certainly not setting \`run-name: role/<job-id>\`, which is the only receipt this check has. Every job reads as missing until it does.")
fi

if [ -f "$caller" ]; then
  # Exact match, not substring: `grep -F '7 14 * * 3'` also matches
  # `17 14 * * 3`, so a one-digit drift in the caller would have passed this
  # check silently — which is the failure the check exists to catch.
  # sed, not grep, and for two reasons. grep exits 1 on no match, which under
  # `set -o pipefail` killed this script before it could report the gaps it had
  # already found — the check crashing instead of firing, on the one run where
  # it mattered. And `- cron: 23 6 * * *` is legal YAML: the crons are not
  # always quoted.
  declared=$(sed -nE "s/^[[:space:]]*-?[[:space:]]*cron:[[:space:]]*['\"]?([^'\"#]+)['\"]?.*\$/\1/p" \
    "$caller" | sed -E 's/[[:space:]]+\$//' | sort -u)
  known=$(jq -r '[.jobs[] | select(.cron != null) | .cron] + [.clock.reserved[]?.cron] | .[]' "$registry" | sort -u)

  while read -r cron; do
    [ -n "$cron" ] || continue
    grep -qxF -- "$cron" <<<"$declared" || \
      problems+=("- cron \`$cron\` is in the registry but not in \`$caller\`, so that job never fires.")
  done <<<"$known"

  while read -r cron; do
    [ -n "$cron" ] || continue
    grep -qxF -- "$cron" <<<"$known" || \
      problems+=("- cron \`$cron\` is in \`$caller\` but is not a registry job or a reserved clock cron, so it fires nothing.")
  done <<<"$declared"
else
  problems+=("- caller workflow \`$caller\` not found in \`$repo\`.")
fi

open=$(gh issue list --repo "$repo" --state open --search "\"$title\" in:title" \
  --json number --jq '.[0].number // ""')

if [ ${#problems[@]} -eq 0 ]; then
  echo "- clock healthy: every registry job ran inside its window" >>"$summary"
  if [ -n "$open" ]; then
    # Amber under agentic-sdlc.md: closing an issue this job opened, said out
    # loud in the same breath.
    gh_do issue close "$open" --repo "$repo" \
      --comment "Clock healthy again — every registry job ran inside its window. Closed by the heartbeat that opened it."
    echo "heartbeat: closed #$open" >&2
  fi
  echo "heartbeat: ok" >&2
  exit 0
fi

body=$(printf '%s\n' \
  "The clock has gaps. Each line is a job in \`roles/registry.json\` that did not do what the registry says it does." \
  "" "${problems[@]}" "" \
  "Checked against the last 100 workflow runs in \`$repo\` and against \`$caller\`.")

if [ -n "$open" ]; then
  gh_do issue comment "$open" --repo "$repo" --body "$body"
  echo "heartbeat: updated #$open with ${#problems[@]} problem(s)" >&2
else
  gh_do issue create --repo "$repo" --title "$title" --body "$body" --label build
  echo "heartbeat: opened an issue with ${#problems[@]} problem(s)" >&2
fi

printf '%s\n' "${problems[@]}" >>"$summary"
echo "::warning::The role clock has ${#problems[@]} gap(s); see the tracking issue."
