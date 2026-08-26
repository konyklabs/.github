#!/usr/bin/env bash
# Turn a role's proposal into GitHub writes. No model runs in this script.
#
# The agent job that produced $RAW holds `contents: read` and nothing else, so
# it could not have posted any of this itself. That is the point: the model
# proposes, this script disposes, and the caps it enforces come from
# registry.json rather than from anything the model said.
#
# Fail-closed on every boundary. A proposal over its cap applies NOTHING — a
# partial apply reads afterwards as "the role only found three things", which is
# the same failure mode as a silently truncated review. An unknown action type,
# a label outside the allowlist and malformed JSON are all hard errors for the
# same reason.
#
# Reads $RAW, $JOB, $REPO, $RUN_URL, $GH_TOKEN. Optional: $ROLE_PROJECT_ID,
# $ESCALATION_ISSUE, $ROLE_STAGE (true = print, apply nothing).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
registry="$here/registry.json"

job=${JOB:?job id}
repo=${REPO:?repo}
stage=${ROLE_STAGE:-false}

entry=$(jq -c --arg id "$job" '.jobs[] | select(.id == $id)' "$registry")
[ -n "$entry" ] || { echo "::error::No job '$job' in registry"; exit 1; }
role=$(jq -r '.role' <<<"$entry")
brief=$(jq -r '.brief' <<<"$entry")
footer_key=$(jq -r '.footer' "$registry")
allowed=$(jq -c '.labels.allowed' "$registry")

# A dead role is not a clean one. An empty structured output means the run did
# not finish, and that is a different outcome from "nothing needed doing".
if [ -z "${RAW:-}" ] || ! jq -e '.actions | type == "array"' >/dev/null 2>&1 <<<"$RAW"; then
  echo "::error::$job returned no structured proposal. Re-run; this is not a clean backlog."
  exit 1
fi

prop=$(mktemp); jq . <<<"$RAW" >"$prop"

{
  echo "### $job — proposal"
  echo
  jq -r '.summary' "$prop" | sed 's/^/> /'
  echo
} >>"$summary"

# --- caps -------------------------------------------------------------------
over=0
while read -r type count; do
  cap=$(jq -r --arg t "$type" '.caps[$t] // 0' <<<"$entry")
  if [ "$count" -gt "$cap" ]; then
    echo "::error::$job proposed $count \`$type\` actions, cap is $cap. Applying nothing."
    over=1
  fi
done < <(jq -r '.actions | group_by(.type)[] | "\(.[0].type) \(length)"' "$prop")

unknown=$(jq -c --argjson a "$allowed" \
  '[.actions[] | select(.labels != null) | .labels[] | select(. as $l | $a | index($l) | not)] | unique' "$prop")
if [ "$unknown" != "[]" ]; then
  echo "::error::$job proposed labels outside the allowlist: $unknown"
  over=1
fi

missing=$(jq -c '[.actions[] | select((.why // "") == "")]' "$prop")
if [ "$missing" != "[]" ]; then
  echo "::error::$job proposed action(s) with no evidence in \`why\`. Applying nothing."
  over=1
fi

[ "$over" -eq 0 ] || exit 1

n=$(jq '.actions | length' "$prop")
if [ "$n" -eq 0 ]; then
  echo "- no actions proposed" >>"$summary"
  echo "apply: job=$job actions=0" >&2
  jq -r '.unresolved // [] | .[] | "- unresolved: \(.)"' "$prop" >>"$summary"
  exit 0
fi

footer=$(printf '\n\n<!-- %s: %s/%s run:%s -->' "$footer_key" "$role" "$brief" "${RUN_URL:-local}")

gh_do() {
  if [ "$stage" = "true" ]; then
    printf 'STAGED: gh %s\n' "$*" >>"$summary"
    return 0
  fi
  gh "$@"
}

# --- apply ------------------------------------------------------------------
applied=0; skipped=0
while read -r action; do
  type=$(jq -r '.type' <<<"$action")
  target=$(jq -r '.target' <<<"$action")
  case "$type" in
    comment)
      body=$(jq -r '.body' <<<"$action")
      gh_do issue comment "$target" --repo "$repo" --body "${body}${footer}"
      ;;
    label|unlabel)
      labels=$(jq -r '.labels | join(",")' <<<"$action")
      flag=--add-label; [ "$type" = unlabel ] && flag=--remove-label
      gh_do issue edit "$target" --repo "$repo" "$flag" "$labels"
      ;;
    create-issue)
      title=$(jq -r '.title' <<<"$action")
      body=$(jq -r '.body' <<<"$action")
      labels=$(jq -r '.labels // [] | join(",")' <<<"$action")
      if [ -n "$labels" ]; then
        gh_do issue create --repo "$repo" --title "$title" --body "${body}${footer}" --label "$labels"
      else
        gh_do issue create --repo "$repo" --title "$title" --body "${body}${footer}"
      fi
      ;;
    close-issue)
      body=$(jq -r '.body' <<<"$action")
      gh_do issue close "$target" --repo "$repo" --comment "${body}${footer}"
      ;;
    escalate)
      body=$(jq -r '.body' <<<"$action")
      dest=$target
      [ "$dest" = "0" ] && dest=${ESCALATION_ISSUE:-}
      if [ -z "$dest" ]; then
        echo "::error::$job escalated with target 0 and no ESCALATION_ISSUE configured. The escalation would have been lost."
        exit 1
      fi
      gh_do issue comment "$dest" --repo "$repo" --body "**Needs Oleg** — from \`$job\`

$body$footer"
      ;;
    set-field)
      if [ -z "${ROLE_PROJECT_ID:-}" ]; then
        # Named out loud rather than dropped. A silently skipped field write
        # looks identical to a board that is already correct.
        echo "- SKIPPED set-field on #$target ($(jq -r '.field' <<<"$action")=$(jq -r '.value' <<<"$action")): no ROLE_PROJECT_ID" >>"$summary"
        skipped=$((skipped + 1)); continue
      fi
      bash "$here/bin/project-field.sh" "$repo" "$target" \
        "$(jq -r '.field' <<<"$action")" "$(jq -r '.value' <<<"$action")"
      ;;
    *)
      echo "::error::Unknown action type '$type'"; exit 1 ;;
  esac
  applied=$((applied + 1))
done < <(jq -c '.actions[]' "$prop")

{
  echo
  echo "| # | type | target | why |"
  echo "|---|---|---|---|"
  jq -r '.actions[] | "| | `\(.type)` | \(if .target == 0 then "—" else "#\(.target)" end) | \(.why | gsub("\\|"; "\\\\|")) |"' "$prop"
  jq -r '.unresolved // [] | .[] | "- unresolved: \(.)"' "$prop"
} >>"$summary"

echo "apply: job=$job applied=$applied skipped=$skipped staged=$stage" >&2
