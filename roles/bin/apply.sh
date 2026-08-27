#!/usr/bin/env bash
# Turn a role's proposal into GitHub writes. No model runs in this script.
#
# The agent job that produced $RAW holds read scopes only — nothing in it can
# write an issue, a pull request or a file — so it could not have posted any of
# this itself. That is the point: the model proposes, this script
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
#   scope      a bound job may only touch the issue it is bound to — the one
#              that triggered it, or the standing report issue
#   labels     every proposed label must exist in the repository, not just in
#              the allowlist
#   board      every set-field value is checked against the live board first,
#              but only when the board is reachable — an unconfigured or
#              unreachable one skips its own actions and says why, instead of
#              failing the comments and labels beside them
#
# Reads $RAW, $JOB, $REPO, $RUN_URL, $GH_TOKEN. Optional: $ISSUE (required for
# a triggering-issue job), $REPORT_ISSUE (required for a report-issue job),
# $ROLE_PROJECT_ID, $ROLE_PROJECT_TOKEN, $ESCALATION_ISSUE, $ROLE_STAGE.
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
scope=$(jq -r '.scope // empty' <<<"$entry")
if [ -z "$scope" ]; then
  echo "::error::Job '$job' has no 'scope' in roles/registry.json, and the permissive value is not a safe default for where a role may write."
  exit 1
fi
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

# --- a label in the allowlist still has to exist in the repository ----------
# The allowlist says which labels a role MAY use; it does not say which ones the
# repository HAS. `gh issue edit --add-label` resolves names client-side and
# exits 1 on an unknown one, which under set -e aborts the loop after earlier
# actions have posted. Nine of the allowlisted labels are not GitHub defaults
# and have to be created by hand, so this is the ordinary state of a new
# consuming repo, not an edge case. Same treatment as the board: one read,
# before the first write.
want=$(jq -c '[.actions[] | select(.labels != null) | .labels[]] | unique' "$prop")
if [ "$want" != "[]" ]; then
  if have=$(gh label list --repo "$repo" --limit 200 --json name --jq '[.[].name]' 2>&1); then
    absent=$(jq -cn --argjson h "$have" --argjson w "$want" \
      '[$w[] | select(. as $l | $h | index($l) | not)]')
    [ "$absent" = "[]" ] || refuse "proposed label(s) \`$repo\` does not have: $absent. Create them, or drop them from registry.json labels.allowed."
  else
    refuse "could not read the labels of \`$repo\`, so a label action cannot be checked before it is applied: $(head -c 200 <<<"$have" | tr '\n' ' ')."
  fi
fi

# --- the board is the one boundary that is not local ------------------------
# Whether a field exists and whether a SINGLE_SELECT option name is real are
# facts only the board has. Checking them inside the apply loop meant a value
# the board rejects aborted the run after earlier actions had already posted.
# The board is read once and every set-field action is checked against it here.
# Both halves or neither. They live on different configuration surfaces — a
# repo variable and a secret — so setting one without the other is the ordinary
# way to arrive here, and a board that is half-configured must skip its own
# actions rather than fail the comments and labels alongside them.
board=false; board_reason=""
if [ -n "${ROLE_PROJECT_ID:-}" ] && [ -n "${ROLE_PROJECT_TOKEN:-}" ]; then
  board=true
else
  [ -z "${ROLE_PROJECT_ID:-}" ] && board_reason="no ROLE_PROJECT_ID"
  [ -z "${ROLE_PROJECT_TOKEN:-}" ] && board_reason="${board_reason:+$board_reason and }no ROLE_PROJECT_TOKEN"
fi

if [ "$board" = "true" ]; then
  fieldcache=$(mktemp); nodecache=$(mktemp)
  export ROLE_FIELDS_CACHE=$fieldcache ROLE_NODE_CACHE=$nodecache
  while read -r act; do
    # Exit 3 means the board could not be read — an expired token, a stale
    # project id, a 502. That is not the model proposing a bad value, and
    # refusing the proposal for it would discard every comment and label
    # beside it while blaming the model in the only message an operator sees.
    # `$?` after an `if` is the status of the if statement, not of the command
    # in its condition, so the code is captured in the else branch where it is
    # still the condition's. Getting this wrong reports every failure as the
    # default arm.
    if out=$(ROLE_STAGE=true bash "$here/bin/project-field.sh" check "$repo" \
        "$(jq -r '.target' <<<"$act")" "$(jq -r '.field' <<<"$act")" "$(jq -r '.value' <<<"$act")" 2>&1); then
      continue
    else
      st=$?
    fi
    case $st in
      3) board=false
         board_reason="board unreachable: $(head -c 200 <<<"$out" | tr '\n' ' ')"
         echo "::warning::$board_reason — set-field actions will be skipped and named."
         break ;;
      *) refuse "proposed a set-field the board rejects: $(jq -c '{target, field, value}' <<<"$act"). $(head -c 200 <<<"$out" | tr '\n' ' ')" ;;
    esac
  done < <(jq -c '.actions[] | select(.type == "set-field")' "$prop")
fi

# --- an escalation must have somewhere to go --------------------------------
homeless=$(jq -r '[.actions[] | select(.type == "escalate" and .target == 0)] | length' "$prop")
if [ "$homeless" -gt 0 ] && [ -z "${ESCALATION_ISSUE:-}" ]; then
  refuse "escalated with target 0 and no ESCALATION_ISSUE is configured, so the escalation would be lost."
fi

# --- a bound job may only touch the issue it is bound to --------------------
# po-intake's primary input is an issue body written by whoever opened it, and
# prompt-level scoping ("not this run's job") is not a boundary; this is.
#
# The cron reporters are bound for a different reason: their briefs say "the
# standing report issue" and nothing in the prompt says which one, so the model
# would pick a number. Binding it means it does not have to.
#
# `create-issue` and `escalate` may use target 0 under any scope — they do not
# act on an existing issue.
case "$scope" in
  triggering-issue) bound=${ISSUE:-};      bound_name="its triggering issue (ISSUE)" ;;
  report-issue)     bound=${REPORT_ISSUE:-}; bound_name="the standing report issue (ROLE_REPORT_ISSUE)" ;;
  *)                bound="" ;;
esac

if [ "$scope" = "triggering-issue" ] || [ "$scope" = "report-issue" ]; then
  if [ -z "$bound" ]; then
    refuse "is scoped to $bound_name but that issue number was not passed to this step."
  else
    stray=$(jq -c --argjson i "$bound" \
      '[.actions[]
        | select((.target != $i)
                 and (.target != 0 or (.type != "escalate" and .type != "create-issue")))
        | {type, target}]' "$prop")
    [ "$stray" = "[]" ] || refuse "is scoped to issue #$bound but proposed actions on others: $stray."
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
      if [ "$board" != "true" ]; then
        # Named out loud rather than dropped. A silently skipped field write
        # looks identical to a board that is already correct.
        echo "- SKIPPED set-field on #$target ($(jq -r '.field' <<<"$act")=$(jq -r '.value' <<<"$act")): ${board_reason:-board unavailable}" >>"$summary"
        skipped=$((skipped + 1)); continue
      fi
      bash "$here/bin/project-field.sh" apply "$repo" "$target" \
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
