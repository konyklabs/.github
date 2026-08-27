#!/usr/bin/env bash
# Turn a role's proposal into GitHub writes. No model runs in this script.
#
# The agent job that produced $RAW holds no write scope, so it could not have
# posted any of this itself. That is the point: the model proposes, this script
# disposes, and what it will accept comes from registry.json rather than from
# anything the model said.
#
# EVERY check runs before the FIRST write. That ordering is the contract — a
# proposal that breaches any boundary applies nothing at all, because a partial
# apply reads afterwards as "the role only found three things", which is the
# same failure mode konyklabs/roadmap#16 records for a truncated review. An
# earlier revision put two of the aborts inside the apply loop and therefore did
# not hold this contract; the checks are all in one pass now.
#
# Residual, stated rather than papered over: a network failure or an API error
# mid-loop can still leave a prefix of the actions applied. Nothing here can
# roll GitHub back. Each action is echoed to the step summary as it lands, so
# that prefix is visible rather than inferred.
#
# The boundaries, in the order they are checked:
#
#   surveyed   a run that read nothing is a failed run, not a clean backlog
#   caps       per action type, from the registry
#   labels     allowlist, from the registry
#   why        every action carries its evidence
#   fields     the fields each action type actually needs
#   escalate   an escalation with nowhere to go fails loudly, never vanishes
#   scope      an event-scoped job may only touch the issue that triggered it
#
# Reads $RAW, $JOB, $REPO, $RUN_URL, $GH_TOKEN. Optional: $ISSUE (required for
# an event-scoped job), $ROLE_PROJECT_ID, $ESCALATION_ISSUE, $ROLE_STAGE.
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
scope=$(jq -r '.scope // "repo"' <<<"$entry")
footer_key=$(jq -r '.footer' "$registry")
allowed=$(jq -c '.labels.allowed' "$registry")

# A dead role is not a clean one. Empty structured output means the run did not
# finish, and that is a different outcome from "nothing needed doing".
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

over=0
refuse() { echo "::error::$job $1 Applying nothing."; over=1; }

# --- did it look at anything? ----------------------------------------------
# The failure this catches is the quiet one: a token without read scope makes
# every `gh` call 403, the model truthfully finds nothing, and an empty proposal
# is indistinguishable from a healthy backlog on every surface downstream.
read_n=$(jq -r '.surveyed.items_read // -1' "$prop")
src_n=$(jq -r '.surveyed.sources // [] | length' "$prop")
if [ "$read_n" -lt 0 ] || [ "$src_n" -eq 0 ]; then
  refuse "returned no \`surveyed\` block, so there is no evidence it read anything."
elif [ "$read_n" -eq 0 ]; then
  refuse "read 0 items. That is a blind run, not a clean backlog — check the token's read scopes."
fi

# --- caps -------------------------------------------------------------------
while read -r type count; do
  cap=$(jq -r --arg t "$type" '.caps[$t] // 0' <<<"$entry")
  [ "$count" -le "$cap" ] || refuse "proposed $count \`$type\` actions, cap is $cap."
done < <(jq -r '.actions | group_by(.type)[] | "\(.[0].type) \(length)"' "$prop")

# --- known types ------------------------------------------------------------
known=$(jq -c '.properties.actions.items.properties.type.enum' "$here/schemas/proposal.json")
bad=$(jq -c --argjson k "$known" '[.actions[].type | select(. as $t | $k | index($t) | not)] | unique' "$prop")
[ "$bad" = "[]" ] || refuse "proposed unknown action type(s): $bad."

# --- labels -----------------------------------------------------------------
unknown=$(jq -c --argjson a "$allowed" \
  '[.actions[] | select(.labels != null) | .labels[] | select(. as $l | $a | index($l) | not)] | unique' "$prop")
[ "$unknown" = "[]" ] || refuse "proposed labels outside the allowlist: $unknown."

# --- evidence ---------------------------------------------------------------
missing=$(jq -c '[.actions[] | select((.why // "") == "") | .type]' "$prop")
[ "$missing" = "[]" ] || refuse "proposed action(s) with no evidence in \`why\`: $missing."

# --- the fields each type actually needs ------------------------------------
short=$(jq -c '[.actions[]
  | select(
      ((.type == "comment" or .type == "close-issue" or .type == "escalate") and ((.body // "") == ""))
   or (.type == "create-issue" and (((.title // "") == "") or ((.body // "") == "")))
   or ((.type == "label" or .type == "unlabel") and (((.labels // []) | length) == 0))
   or (.type == "set-field" and (((.field // "") == "") or ((.value // "") == "")))
    )
  | {type, target}]' "$prop")
[ "$short" = "[]" ] || refuse "proposed action(s) missing the fields their type needs: $short."

# `target: 0` is schema-legal and meaningful for create-issue and escalate. For
# everything else it is an issue number that is not an issue, and `gh issue
# comment 0` fails — mid-loop, after earlier actions have landed. Checked here
# so it cannot.
targetless=$(jq -c '[.actions[]
  | select((.type != "create-issue" and .type != "escalate") and ((.target // 0) <= 0))
  | {type, target}]' "$prop")
[ "$targetless" = "[]" ] || refuse "proposed action(s) with no issue number to act on: $targetless."

# --- an escalation must have somewhere to go --------------------------------
homeless=$(jq -r '[.actions[] | select(.type == "escalate" and .target == 0)] | length' "$prop")
if [ "$homeless" -gt 0 ] && [ -z "${ESCALATION_ISSUE:-}" ]; then
  refuse "escalated with target 0 and no ESCALATION_ISSUE is configured, so the escalation would be lost."
fi

# --- an event-scoped job may only touch its own issue -----------------------
# po-intake's primary input is an issue body and comments written by whoever
# opened it. Prompt-level scoping ("not this run's job") is not a boundary; this
# is. Without it, text in an issue can direct writes at any other issue.
if [ "$scope" = "triggering-issue" ]; then
  if [ -z "${ISSUE:-}" ]; then
    refuse "is scoped to its triggering issue but no ISSUE was passed to this step."
  else
    stray=$(jq -c --argjson i "${ISSUE:-0}" \
      '[.actions[] | select((.target != $i) and (.target != 0 or .type != "escalate")) | {type, target}]' "$prop")
    [ "$stray" = "[]" ] || refuse "is scoped to issue #$ISSUE but proposed actions on others: $stray."
  fi
fi

[ "$over" -eq 0 ] || exit 1

n=$(jq '.actions | length' "$prop")
{
  echo "- surveyed: $read_n item(s) via $src_n source(s)"
  jq -r '.surveyed.sources[] | "  - \(.)"' "$prop"
} >>"$summary"

if [ "$n" -eq 0 ]; then
  echo "- no actions proposed" >>"$summary"
  jq -r '.unresolved // [] | .[] | "- unresolved: \(.)"' "$prop" >>"$summary"
  echo "apply: job=$job read=$read_n actions=0" >&2
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

applied=0; skipped=0
while read -r act; do
  type=$(jq -r '.type' <<<"$act")
  target=$(jq -r '.target' <<<"$act")
  case "$type" in
    comment)
      gh_do issue comment "$target" --repo "$repo" --body "$(jq -r '.body' <<<"$act")$footer" ;;
    label)
      gh_do issue edit "$target" --repo "$repo" --add-label "$(jq -r '.labels | join(",")' <<<"$act")" ;;
    unlabel)
      gh_do issue edit "$target" --repo "$repo" --remove-label "$(jq -r '.labels | join(",")' <<<"$act")" ;;
    create-issue)
      labels=$(jq -r '.labels // [] | join(",")' <<<"$act")
      if [ -n "$labels" ]; then
        gh_do issue create --repo "$repo" --title "$(jq -r '.title' <<<"$act")" \
          --body "$(jq -r '.body' <<<"$act")$footer" --label "$labels"
      else
        gh_do issue create --repo "$repo" --title "$(jq -r '.title' <<<"$act")" \
          --body "$(jq -r '.body' <<<"$act")$footer"
      fi ;;
    close-issue)
      gh_do issue close "$target" --repo "$repo" --comment "$(jq -r '.body' <<<"$act")$footer" ;;
    escalate)
      dest=$target; [ "$dest" = "0" ] && dest=$ESCALATION_ISSUE
      gh_do issue comment "$dest" --repo "$repo" --body "**Needs Oleg** — from \`$job\`

$(jq -r '.body' <<<"$act")$footer" ;;
    set-field)
      if [ -z "${ROLE_PROJECT_ID:-}" ]; then
        # Named out loud rather than dropped. A silently skipped field write
        # looks identical to a board that is already correct.
        echo "- SKIPPED set-field on #$target ($(jq -r '.field' <<<"$act")=$(jq -r '.value' <<<"$act")): no ROLE_PROJECT_ID" >>"$summary"
        skipped=$((skipped + 1)); continue
      fi
      bash "$here/bin/project-field.sh" "$repo" "$target" \
        "$(jq -r '.field' <<<"$act")" "$(jq -r '.value' <<<"$act")" ;;
  esac
  applied=$((applied + 1))
  echo "- applied \`$type\` on $([ "$target" = "0" ] && echo "—" || echo "#$target")" >>"$summary"
done < <(jq -c '.actions[]' "$prop")

{
  echo
  echo "| type | target | why |"
  echo "|---|---|---|"
  jq -r '.actions[] | "| `\(.type)` | \(if .target == 0 then "—" else "#\(.target)" end) | \(.why | gsub("\\|"; "\\\\|")) |"' "$prop"
  jq -r '.unresolved // [] | .[] | "- unresolved: \(.)"' "$prop"
} >>"$summary"

echo "apply: job=$job read=$read_n applied=$applied skipped=$skipped staged=$stage" >&2
