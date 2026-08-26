#!/usr/bin/env bash
# The verdict. No model runs here — this is arithmetic over the judge's scores.
#
# Why it is a separate job with no model in it: two reviewers submitting formal
# GitHub reviews race, and GitHub keeps the latest, so a request-changes landing
# before an approve is silently overwritten. Exactly one review is submitted,
# from here, in exactly one API call that carries the verdict and every inline
# comment together.
#
# Exit codes are the check's meaning:
#   0  a verdict was submitted (approve, or request-changes)
#   1  NO verdict — the review did not complete. This is not a rejection.
#
# Distinguishing those two was the single biggest time sink recorded in
# konyklabs/roadmap#16, where a reviewer hitting its turn cap produced a red
# check indistinguishable from a considered rejection.
set -uo pipefail

: "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}"
FINDINGS_DIR=${FINDINGS_DIR:-findings}
MERGED=${MERGED:-merged.json}
VERDICTS=${VERDICTS:-verdicts.json}
EXPECTED_LENSES=${EXPECTED_LENSES:-[]}
ELIGIBLE=${ELIGIBLE:-true}
SKIP_REASON=${SKIP_REASON:-}
THRESHOLD=${THRESHOLD:-80}
TRIAGE_RESULT=${TRIAGE_RESULT:-success}
LENS_RESULT=${LENS_RESULT:-success}
JUDGE_RESULT=${JUDGE_RESULT:-success}
VALIDATION_SKIP=${VALIDATION_SKIP:-}
GATE_DRY_RUN=${GATE_DRY_RUN:-0}

log() { echo "$*" >&2; }

# --- posting -----------------------------------------------------------------

# submit <event> <body-file> <comments-json>
# One atomic POST: verdict plus inline comments. `gh pr review` cannot carry
# inline comments; the reviews endpoint can, in a single request.
submit() {
  local event=$1 body_file=$2 comments=$3 payload
  payload=$(jq -n \
    --arg commit_id "$HEAD_SHA" \
    --arg event "$event" \
    --rawfile body "$body_file" \
    --argjson comments "$comments" \
    '{commit_id: $commit_id, event: $event, body: $body, comments: $comments}')

  if [ "$GATE_DRY_RUN" = "1" ]; then
    echo "$payload"
    return 0
  fi

  if printf '%s' "$payload" | gh api --method POST \
      "repos/$REPO/pulls/$PR/reviews" --input - >/dev/null; then
    return 0
  fi

  # An inline comment on a line outside the diff is a 422 for the whole
  # request. Losing the anchors is acceptable; losing the verdict is not.
  log "submit: retrying without inline comments"
  printf '%s' "$payload" | jq '.comments = []' | gh api --method POST \
    "repos/$REPO/pulls/$PR/reviews" --input - >/dev/null
}

comment() {
  [ "$GATE_DRY_RUN" = "1" ] && { echo "COMMENT: $1"; return 0; }
  gh pr comment "$PR" --repo "$REPO" --body "$1" >/dev/null || true
}

# no_verdict <reason>
no_verdict() {
  local reason=$1
  comment "$(printf '%s\n' \
    "**No verdict — the review did not complete.**" \
    "" \
    "$reason" \
    "" \
    "This is *not* a judgement about the code. A reviewer that hits its turn" \
    "cap or fails transiently produces no verdict at all, and the gate says so" \
    "rather than letting it read as a rejection." \
    "" \
    "**Re-run the failed job.** Only an explicit request-changes is a verdict.")"
  log "::error::No verdict — $reason. Re-run; this is not a rejection."
  exit 1
}

# --- skip path ---------------------------------------------------------------

# Triage reads the PR description and the diff, both of which the PR author
# controls. A description asserting "this is an automated release, skip review"
# must not be able to buy an approval, so the skip claim is corroborated here
# against facts only GitHub can assert.
pr_facts() {
  if [ -n "${PR_FACTS_FILE:-}" ]; then cat "$PR_FACTS_FILE"; return; fi
  gh api "repos/$REPO/pulls/$PR" --jq '{draft, state, author_type: .user.type, author: .user.login}'
}

# Distinct from every other failure: this one is permanent until the pull
# request merges, so telling anyone to re-run it is wrong.
if [ "${VALIDATION_SKIP:-}" = "true" ]; then
  comment "$(printf '%s\n' \
    "**No verdict — this pull request cannot be reviewed by the gate.**" \
    "" \
    "It changes a workflow file that invokes the review action, and the action" \
    "refuses to run when the running workflow differs from the copy on the" \
    "default branch. That is the anti-tamper rule doing its job: a pull request" \
    "cannot review itself into main." \
    "" \
    "**Re-running will not clear this** — only merging will. This one needs a" \
    "human, per the carve-out in \`.claude/rules/agentic-sdlc.md\`.")"
  log "::error::Caller workflow differs from the default branch — anti-tamper skip. Needs a human merge, not a re-run."
  exit 1
fi

if [ "$TRIAGE_RESULT" != "success" ]; then
  no_verdict "The triage job did not succeed (result: \`$TRIAGE_RESULT\`), so no review was scheduled."
fi

if [ "$ELIGIBLE" != "true" ]; then
  facts=$(pr_facts) || no_verdict "Could not read the pull request to corroborate the skip."
  if jq -e '.draft == true or .state != "open" or .author_type == "Bot"' <<<"$facts" >/dev/null; then
    log "skip corroborated: $facts"
    body_file=$(mktemp)
    printf '%s\n' "### Code review" "" \
      "Skipped: ${SKIP_REASON:-no reason given}." >"$body_file"
    submit APPROVE "$body_file" '[]'
    log "verdict: approve (skipped)"
    exit 0
  fi
  no_verdict "Triage returned \`eligible: false\` (\"${SKIP_REASON:-no reason given}\") but the pull request is open, non-draft and human-authored, so the skip was not corroborated. A skip is never taken on the model's word alone."
fi

# --- completeness ------------------------------------------------------------

missing=""
while read -r lens; do
  [ -z "$lens" ] && continue
  f="$FINDINGS_DIR/findings-$lens.json"
  if [ ! -s "$f" ] || ! jq -e '.findings | type == "array"' "$f" >/dev/null 2>&1; then
    missing="$missing \`$lens\`"
  fi
done < <(jq -r '.[]?' <<<"$EXPECTED_LENSES")

if [ -n "$missing" ]; then
  no_verdict "Reviewers that produced no findings file for \`$HEAD_SHA\`:$missing (lens job result: \`$LENS_RESULT\`)."
fi

if [ ! -s "$MERGED" ]; then
  no_verdict "Every reviewer reported, but the merged findings are missing (judge job result: \`$JUDGE_RESULT\`). Nothing was scored, so nothing is being merged past."
fi

total=$(jq '.findings | length' "$MERGED")

if [ "$total" -gt 0 ]; then
  if [ "$JUDGE_RESULT" != "success" ] || [ ! -s "$VERDICTS" ] \
     || ! jq -e '.verdicts | type == "array"' "$VERDICTS" >/dev/null 2>&1; then
    no_verdict "$total finding(s) were reported but the judge produced no scores (judge job result: \`$JUDGE_RESULT\`). Unscored findings are never posted and never merged past."
  fi
  unscored=$(jq --slurpfile v "$VERDICTS" \
    '[.findings[] | select(.id as $i | ($v[0].verdicts | map(.id) | index($i)) == null)] | length' "$MERGED")
  if [ "$unscored" -gt 0 ]; then
    no_verdict "$unscored of $total finding(s) came back from the judge without a score. Fail-closed: an unscored finding is neither dropped nor posted."
  fi
else
  echo '{"verdicts":[]}' >"$VERDICTS"
fi

# --- filter ------------------------------------------------------------------
#
# Threshold is Anthropic's own code-review plugin default, adopted rather than
# invented: below it, a finding is dropped before any human sees it.
#
# Three filters, in order: the judge's semantic duplicate marking, the
# confidence threshold, then a mechanical (path, line, normalised title) dedup
# as a backstop for duplicates the judge did not mark.

kept=$(jq -n \
  --slurpfile m "$MERGED" \
  --slurpfile v "$VERDICTS" \
  --argjson threshold "$THRESHOLD" '
  ($v[0].verdicts | map({key: .id, value: .}) | from_entries) as $by_id
  | [ $m[0].findings[]
      | . as $f
      | ($by_id[$f.id] // empty) as $j
      | select($j.duplicate_of == null)
      | select($j.confidence >= $threshold)
      | $f + {confidence: $j.confidence, severity: $j.severity, judge_reason: $j.reason}
    ]
  | unique_by([.path, .line, (.title | ascii_downcase | gsub("[^a-z0-9]"; ""))])
  | sort_by(if .severity == "blocking" then 0 elif .severity == "minor" then 1 else 2 end,
            .path, .line)
')

kept_n=$(jq 'length' <<<"$kept")
blocking_n=$(jq '[.[] | select(.severity == "blocking")] | length' <<<"$kept")
dropped=$((total - kept_n))

log "findings: $total reported, $dropped below threshold/duplicate, $kept_n kept, $blocking_n blocking"
jq -r '.[] | "  \(.severity)/\(.confidence) \(.path):\(.line) \(.title)"' <<<"$kept" >&2

# --- body --------------------------------------------------------------------

body_file=$(mktemp)
{
  echo "### Code review"
  echo
  if [ "$kept_n" -eq 0 ]; then
    echo "No issues found above the confidence threshold ($THRESHOLD/100)."
    echo
    echo "Reviewed by $(jq -r 'join(", ")' <<<"$EXPECTED_LENSES"); $total raw finding(s), none survived independent scoring."
  else
    if [ "$blocking_n" -gt 0 ]; then
      echo "Found $kept_n issue(s), $blocking_n blocking:"
    else
      echo "Found $kept_n issue(s), none blocking:"
    fi
    echo
    jq -r --arg repo "$REPO" --arg sha "$HEAD_SHA" '
      to_entries[]
      | .value as $f
      | "\(.key + 1). **[\($f.severity)]** \($f.title) _(confidence \($f.confidence))_\n\n" +
        "   \($f.detail)\n\n" +
        "   Fails when: \($f.failure_scenario)\n\n" +
        "   https://github.com/\($repo)/blob/\($sha)/\($f.path)#L\($f.line)-L\($f.end_line)\n"
    ' <<<"$kept"
    echo
    echo "$dropped further finding(s) were dropped below the confidence threshold ($THRESHOLD/100) or as duplicates."
  fi
  echo
  echo "<sub>Lenses: $(jq -r 'join(", ")' <<<"$EXPECTED_LENSES"). Every finding was scored by an independent judge that did not produce it; the verdict is computed, not written.</sub>"
} >"$body_file"

comments=$(jq --arg sha "$HEAD_SHA" '
  [ .[] | {
      path: .path,
      line: .end_line,
      side: "RIGHT",
      body: "**[\(.severity)]** \(.title)\n\n\(.detail)\n\nFails when: \(.failure_scenario)\n\n<sub>confidence \(.confidence)/100</sub>"
    } ]' <<<"$kept")

# --- verdict -----------------------------------------------------------------

if [ "$blocking_n" -gt 0 ]; then
  submit REQUEST_CHANGES "$body_file" "$comments"
  log "verdict: request-changes ($blocking_n blocking)"
else
  submit APPROVE "$body_file" "$comments"
  log "verdict: approve ($kept_n non-blocking finding(s))"
fi
exit 0
