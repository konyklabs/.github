#!/usr/bin/env bash
# Turn the triage brief into the lens matrix.
#
# Triage chooses lens IDS ONLY. What each lens costs — model, effort, turn cap,
# checkout depth — comes from review/matrix.json, so a reviewer cannot vote
# itself more compute, and changing the budget is a reviewable diff rather than
# a change in model behaviour.
#
# Reads $RAW (the triage job structured output). Writes step outputs:
#   eligible, skip_reason, lenses, matrix, brief
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

# The action refuses to mint its token when the running workflow differs from
# the copy on the default branch. That is the anti-tamper rule, not a fault, and
# re-running never clears it — only merging does. Saying "re-run" here would
# send someone round a loop that cannot terminate.
if [ "${VALIDATION_SKIP:-}" = "true" ]; then
  echo "validation_skip=true" >>"$out"
  echo "::error::The caller workflow differs from the default branch, so the review action refused to run. Re-running will not help; this needs a human merge."
  exit 1
fi

if [ -z "${RAW:-}" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$RAW"; then
  echo "::error::Triage returned no structured output. Re-run; this is not a rejection."
  exit 1
fi

brief_file=$(mktemp)
jq . <<<"$RAW" >"$brief_file"

for field in eligible tier lenses; do
  if ! jq -e --arg f "$field" 'has($f)' "$brief_file" >/dev/null; then
    echo "::error::Triage output is missing required field '$field'"
    exit 1
  fi
done

eligible=$(jq -r '.eligible' "$brief_file")
tier=$(jq -r '.tier' "$brief_file")
lenses=$(jq -c '.lenses' "$brief_file")

known=$(jq -c '[.lenses[].id]' "$here/matrix.json")
unknown=$(jq -c --argjson known "$known" '[.[] | select(. as $l | $known | index($l) | not)]' <<<"$lenses")
if [ "$unknown" != "[]" ]; then
  echo "::error::Triage asked for lenses that do not exist: $unknown"
  exit 1
fi

if [ "$eligible" = "true" ] && [ "$lenses" = "[]" ]; then
  echo "::error::Triage marked the pull request eligible but selected no lenses"
  exit 1
fi

matrix=$(jq -c --argjson ids "$lenses" \
  '{include: [.lenses[] | select(.id as $i | $ids | index($i))]}' \
  "$here/matrix.json")

detail=$(jq -c '{summary, risk_areas, must_verify}' "$brief_file")
delim="GATE_$(printf '%s' "$detail" | sha256sum | cut -c1-32)"

{
  echo "eligible=$eligible"
  echo "skip_reason=$(jq -r '.skip_reason // ""' "$brief_file" | tr '\n' ' ')"
  echo "lenses=$lenses"
  echo "matrix=$matrix"
  echo "brief<<$delim"
  printf '%s\n' "$detail"
  echo "$delim"
} >>"$out"

{
  echo "### Triage"
  echo
  echo "- eligible: \`$eligible\`"
  echo "- tier: \`$tier\`"
  echo "- lenses: \`$lenses\`"
  echo
  echo '```json'
  jq '{summary, risk_areas, must_verify}' "$brief_file"
  echo '```'
} >>"$summary"

echo "plan: eligible=$eligible tier=$tier lenses=$lenses" >&2
