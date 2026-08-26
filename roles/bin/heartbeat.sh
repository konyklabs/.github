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
#   2. A cron in the registry does not appear in the caller workflow. GitHub
#      cannot read a cron out of a JSON file, so those two lists are duplicated;
#      this check is the price of that duplication being safe.
#
# Reads $REPO, $CALLER (default .github/workflows/roles.yml), $GH_TOKEN.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
registry="$here/registry.json"
repo=${REPO:?repo}
caller=${CALLER:-.github/workflows/roles.yml}
title="Role clock: scheduled jobs are not running"

secs() { # 36h / 8d / 90m -> seconds
  local w=$1 n=${1%[hdm]} u=${1: -1}
  case "$u" in h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; m) echo $((n * 60)) ;;
    *) echo "::error::Bad window '$w' in registry"; exit 1 ;; esac
}

runs=$(gh api "/repos/$repo/actions/runs?per_page=100" \
  --jq '[.workflow_runs[] | {name: .display_title, at: .created_at, concl: .conclusion, url: .html_url}]')

now=$(date -u +%s)
problems=()

while read -r entry; do
  id=$(jq -r '.id' <<<"$entry")
  window=$(jq -r '.window' <<<"$entry")
  [ "$window" = "null" ] && continue

  last=$(jq -c --arg n "role/$id" '[.[] | select(.name == $n)] | sort_by(.at) | last' <<<"$runs")
  if [ "$last" = "null" ]; then
    problems+=("- \`$id\` — **no run found** in the last 100 runs of \`$repo\`.")
    continue
  fi
  at=$(jq -r '.at' <<<"$last")
  age=$(( now - $(date -u -d "$at" +%s) ))
  limit=$(secs "$window")
  concl=$(jq -r '.concl' <<<"$last")
  url=$(jq -r '.url' <<<"$last")
  if [ "$age" -gt "$limit" ]; then
    problems+=("- \`$id\` — last run $((age / 3600))h ago, window is \`$window\`. [run]($url)")
  elif [ "$concl" != "success" ]; then
    problems+=("- \`$id\` — ran $((age / 3600))h ago but concluded \`$concl\`. [run]($url)")
  fi
done < <(jq -c '.jobs[]' "$registry")

if [ -f "$caller" ]; then
  while read -r cron; do
    grep -qF -- "$cron" "$caller" || \
      problems+=("- cron \`$cron\` is in the registry but not in \`$caller\`, so that job never fires.")
  done < <(jq -r '.jobs[] | select(.cron != null) | .cron' "$registry")
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
    gh issue close "$open" --repo "$repo" \
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
  gh issue comment "$open" --repo "$repo" --body "$body"
  echo "heartbeat: updated #$open with ${#problems[@]} problem(s)" >&2
else
  gh issue create --repo "$repo" --title "$title" --body "$body" --label build
  echo "heartbeat: opened an issue with ${#problems[@]} problem(s)" >&2
fi

printf '%s\n' "${problems[@]}" >>"$summary"
echo "::warning::The role clock has ${#problems[@]} gap(s); see the tracking issue."
