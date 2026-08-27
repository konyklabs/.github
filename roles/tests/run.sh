#!/usr/bin/env bash
# Test the half of the role system that has no model in it.
#
# What is asserted here is exactly what stands between a subverted or sloppy
# role and the backlog: the caps, the label allowlist, the evidence requirement,
# and the refusal to apply anything at all when one of them is breached. A
# partial apply is the failure this file exists to prevent, so several tests
# assert that nothing was written rather than that the right thing was.
#
# Pure bash and jq, no bats, so CI needs nothing installed.
#
# Usage: roles/tests/run.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
roles=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# macOS has shasum, CI has sha256sum. compose.sh wants the latter.
mkdir -p "$work/bin"
if ! command -v sha256sum >/dev/null; then
  printf '#!/usr/bin/env bash\nshasum -a 256 "$@"\n' >"$work/bin/sha256sum"
  chmod +x "$work/bin/sha256sum"
fi
PATH="$work/bin:$PATH"

# A `gh` that answers reads from fixtures and records writes, so anything that
# would have written to a real repository is visible as a failed assertion
# rather than as a comment on an issue.
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
log=${GH_LOG:-/dev/null}
sub=$1; shift
jq_of() { local f='.'; while [ $# -gt 0 ]; do if [ "$1" = "--jq" ]; then f=$2; fi; shift; done; printf '%s' "$f"; }
case "$sub" in
  api)
    f=$(jq_of "$@")
    case "$1$f" in
      *addProjectV2ItemById*) echo "ITEM_ID" ;;
      *node.fields*)          printf '%s' "${GH_FIELDS:-[]}" ;;
      *node_id*)              echo "ISSUE_NODE" ;;
      *graphql*)              echo "WRITE: graphql $*" >>"$log" ;;
      *)                      jq -c "$f" <<<"${GH_RUNS_RAW:-{\"workflow_runs\":[]\}}" ;;
    esac ;;
  issue)
    act=$1; shift
    if [ "$act" = list ]; then jq -r "$(jq_of "$@")" <<<"${GH_OPEN_RAW:-[]}"
    else echo "WRITE: issue $act $*" >>"$log"; fi ;;
  *) echo "WRITE: $sub $*" >>"$log" ;;
esac
STUB
chmod +x "$work/bin/gh"


pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n'   "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
group(){ printf '\n%s\n' "$1"; }

assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_grep(){ if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "no match for [$2] in: $3"; fi; }
assert_no_grep(){ if grep -qF -- "$2" <<<"$3"; then bad "$1" "unexpected [$2] in: $3"; else ok "$1"; fi; }

# action <type> <target> <why> [extra jq object]
action() {
  local extra=${4:-}
  [ -n "$extra" ] || extra='{}'
  jq -c -n --arg t "$1" --argjson n "$2" --arg w "$3" --argjson x "$extra" \
    '{type: $t, target: $n, why: $w} + $x'
}
proposal() { jq -c -n --argjson a "$(jq -sc '.' <<<"$*")" \
  '{summary: "test", surveyed: {items_read: 12, sources: ["gh issue list"]}, actions: $a}'; }

# run_apply <job> <proposal-json>  -> sets $out (stdout+stderr), $rc, $sum (step summary)
run_apply() {
  sum="$work/summary.md"; : >"$sum"; : >"$work/gh.log"
  out=$(RAW="$2" JOB="$1" REPO="konyklabs/roadmap" RUN_URL="test" ROLE_STAGE=${STAGE:-true} \
        ISSUE="${ISSUE_UNDER_TEST:-}" ESCALATION_ISSUE="${ESC:-}" GH_LOG="$work/gh.log" \
        ROLE_PROJECT_ID="${PROJ:-}" ROLE_PROJECT_TOKEN="${PROJTOK:-}" \
        GITHUB_STEP_SUMMARY="$sum" bash "$roles/bin/apply.sh" 2>&1); rc=$?
}

# ---------------------------------------------------------------------------
group "registry is coherent with the files it names"

while read -r id role brief; do
  if [ -f "$roles/agents/$role.md" ]; then ok "charter exists for $id"
  else bad "charter exists for $id" "$roles/agents/$role.md"; fi
  if [ -f "$roles/runs/$role/$brief.md" ]; then ok "brief exists for $id"
  else bad "brief exists for $id" "$roles/runs/$role/$brief.md"; fi
done < <(jq -r '.jobs[] | "\(.id) \(.role) \(.brief)"' "$roles/registry.json")

types=$(jq -r '.properties.actions.items.properties.type.enum[]' "$roles/schemas/proposal.json" | sort)
capkeys=$(jq -r '[.jobs[].caps | keys[]] | unique[]' "$roles/registry.json" | sort)
assert_eq "every cap key is a schema action type" "" "$(comm -13 <(echo "$types") <(echo "$capkeys"))"

# Every enum member must have a case arm in apply.sh, or it fails closed at
# runtime on an action the schema told the model was legal.
for t in $types; do
  if grep -qE "^    ${t}[|)]|\\|${t}\\)" "$roles/bin/apply.sh"; then ok "apply.sh handles '$t'"
  else bad "apply.sh handles '$t'"; fi
done

assert_no_grep "schema has no single quote (it is passed inside --json-schema '...')" \
  "'" "$(cat "$roles/schemas/proposal.json")"

# ---------------------------------------------------------------------------
group "compose resolves a job from the registry, not from the caller"

o="$work/out.txt"; : >"$o"
JOB=dm-flow-sweep REPO=konyklabs/roadmap RUN_URL=test \
  GITHUB_OUTPUT="$o" GITHUB_STEP_SUMMARY=/dev/null bash "$roles/bin/compose.sh" >/dev/null 2>&1
assert_grep "budget comes from the registry" "model=sonnet" "$(cat "$o")"
assert_grep "turn cap comes from the registry" "max_turns=90" "$(cat "$o")"
assert_grep "prompt carries the shared ground rules" "You propose. You do not dispose." "$(cat "$o")"
assert_grep "prompt carries the charter" "Owns" "$(cat "$o")"
assert_grep "prompt carries the caps it will be judged against" '"comment":4' "$(cat "$o")"

: >"$o"
JOB=po-intake ISSUE=42 REPO=konyklabs/roadmap \
  GITHUB_OUTPUT="$o" GITHUB_STEP_SUMMARY=/dev/null bash "$roles/bin/compose.sh" >/dev/null 2>&1
assert_grep "brief placeholders are substituted" "gh issue view 42 --repo konyklabs/roadmap" "$(cat "$o")"
assert_grep "an event-scoped job is told what it is bound to" "issue #42 only" "$(cat "$o")"

: >"$o"
JOB=dm-flow-sweep REPO=konyklabs/roadmap \
  GITHUB_OUTPUT="$o" GITHUB_STEP_SUMMARY=/dev/null bash "$roles/bin/compose.sh" >/dev/null 2>&1
assert_no_grep "a repo-scoped job is not" "issue #" "$(cat "$o")"

: >"$o"
JOB=not-a-job GITHUB_OUTPUT="$o" GITHUB_STEP_SUMMARY=/dev/null \
  bash "$roles/bin/compose.sh" >"$work/e" 2>&1; rc=$?
assert_eq "unknown job id fails" "1" "$rc"
assert_grep "unknown job id says why" "does not exist" "$(cat "$work/e")"

# ---------------------------------------------------------------------------
group "apply refuses, and refuses completely"

run_apply dm-weekly-report "$(proposal \
  "$(action comment 3 'last comment 2026-07-02')" \
  "$(action comment 4 'last comment 2026-07-03')")"
assert_eq "over the comment cap fails" "1" "$rc"
assert_grep "over cap names the cap" "cap is 1" "$out"
assert_no_grep "over cap applies nothing" "STAGED" "$(cat "$sum")"

run_apply dm-flow-sweep "$(proposal \
  "$(action label 3 'stale since 2026-07-02' '{"labels":["wontfix"]}')")"
assert_eq "label outside the allowlist fails" "1" "$rc"
assert_grep "allowlist breach names the label" "wontfix" "$out"
assert_no_grep "allowlist breach applies nothing" "STAGED" "$(cat "$sum")"

run_apply dm-flow-sweep "$(jq -c -n '{summary:"t",actions:[{type:"comment",target:3,why:"",body:"x"}]}')"
assert_eq "an action with no evidence fails" "1" "$rc"
assert_grep "no-evidence names the field" "why" "$out"

run_apply dm-flow-sweep "$(jq -c -n '{summary:"t",actions:[{type:"merge-pr",target:3,why:"because"}]}')"
assert_eq "an unknown action type fails" "1" "$rc"

run_apply dm-flow-sweep ""
assert_eq "empty structured output fails" "1" "$rc"
assert_grep "empty output is not read as a clean backlog" "not a clean backlog" "$out"

run_apply dm-flow-sweep '{"summary":"t"}'
assert_eq "a proposal with no actions array fails" "1" "$rc"

# ---------------------------------------------------------------------------
group "apply proceeds when the proposal is inside its contract"

run_apply dm-flow-sweep "$(jq -c -n '{summary:"nothing to do",surveyed:{items_read:31,sources:["gh issue list"]},actions:[],unresolved:["priority is the product owner ground"]}')"
assert_eq "an empty backlog is a success" "0" "$rc"
assert_grep "an empty backlog says so" "no actions proposed" "$(cat "$sum")"
assert_grep "unresolved is carried through" "product owner ground" "$(cat "$sum")"

run_apply dm-flow-sweep "$(proposal \
  "$(action comment 3 'open 21d, last event push 2026-08-05' '{"body":"Stalled 21 days."}')" \
  "$(action label 3 'same' '{"labels":["stale"]}')")"
assert_eq "a proposal inside its caps applies" "0" "$rc"
assert_grep "comment is staged" "issue comment 3" "$(cat "$sum")"
assert_grep "label is staged" "--add-label stale" "$(cat "$sum")"
assert_grep "the why reaches the step summary" "open 21d" "$(cat "$sum")"

run_apply arch-drift-audit "$(proposal \
  "$(action escalate 0 'D-002 contradicts pyproject.toml:14' '{"body":"D-002 needs superseding."}')")"
assert_eq "escalate with no home fails rather than vanishing" "1" "$rc"
assert_grep "escalate with no home says where it would have gone" "ESCALATION_ISSUE" "$out"

ISSUE_UNDER_TEST=3 run_apply po-intake \
  "$(proposal "$(action set-field 3 'ready per the four-part test' '{"field":"Status","value":"Ready"}')")"
assert_eq "set-field with no board configured still succeeds" "0" "$rc"
assert_grep "set-field with no board is named, not dropped" "SKIPPED set-field" "$(cat "$sum")"

# ---------------------------------------------------------------------------
group "the dead-man's switch"


ago() { # <seconds ago> -> ISO-8601 Z, GNU then BSD
  date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}
run_of() { jq -c -n --arg t "role/$1" --arg a "$(ago "$2")" --arg c "${3:-success}" \
  '{display_title:$t, created_at:$a, conclusion:$c, html_url:"u"}'; }

# A caller that contains every registry cron, so the cron check is quiet unless
# a test deliberately breaks it.
caller_ok="$work/caller-ok.yml"
jq -r '.jobs[] | select(.cron != null) | "    - cron: \"\(.cron)\""' "$roles/registry.json" >"$caller_ok"

# run_hb <runs-json-array> <caller-file> [open-issue-json]
run_hb() {
  sum="$work/hb.md"; : >"$sum"; : >"$work/gh.log"
  out=$(GH_RUNS_RAW="$(jq -c -n --argjson r "$1" '{workflow_runs: $r}')" \
        GH_OPEN_RAW="${3:-[]}" GH_LOG="$work/gh.log" \
        REPO=konyklabs/roadmap CALLER="$2" ROLE_STAGE=true \
        GITHUB_STEP_SUMMARY="$sum" bash "$roles/bin/heartbeat.sh" 2>&1); rc=$?
}

all_fresh=$(jq -c -n --argjson a "$(run_of dm-flow-sweep 3600)" \
                     --argjson b "$(run_of po-backlog-review 3600)" \
                     --argjson c "$(run_of dm-weekly-report 3600)" \
                     --argjson d "$(run_of arch-drift-audit 3600)" '[$a,$b,$c,$d]')

run_hb "$all_fresh" "$caller_ok"
assert_eq "a healthy clock exits 0" "0" "$rc"
assert_grep "a healthy clock says so" "clock healthy" "$(cat "$sum")"
assert_eq "a healthy clock writes nothing" "" "$(cat "$work/gh.log")"

stale=$(jq -c --argjson s "$(run_of dm-flow-sweep 200000)" '[.[] | select(.display_title != "role/dm-flow-sweep")] + [$s]' <<<"$all_fresh")
run_hb "$stale" "$caller_ok"
assert_grep "a job past its window is caught" "dm-flow-sweep" "$(cat "$sum")"
assert_grep "the gap names the window" "\`36h\`" "$(cat "$sum")"
assert_grep "the tracking issue is staged, not opened" "STAGED: gh issue create" "$(cat "$sum")"
assert_eq "staging makes no real write" "" "$(cat "$work/gh.log")"

missing=$(jq -c '[.[] | select(.display_title != "role/arch-drift-audit")]' <<<"$all_fresh")
run_hb "$missing" "$caller_ok"
assert_grep "a job that never ran is caught" "no run found" "$(cat "$sum")"

failed=$(jq -c --argjson f "$(run_of dm-weekly-report 3600 failure)" '[.[] | select(.display_title != "role/dm-weekly-report")] + [$f]' <<<"$all_fresh")
run_hb "$failed" "$caller_ok"
assert_grep "a job that ran but failed is caught" "concluded \`failure\`" "$(cat "$sum")"

run_hb "$all_fresh" "$work/caller-missing-cron.yml"
assert_grep "a caller that does not exist is caught" "not found" "$(cat "$sum")"

grep -v '23 6' "$caller_ok" >"$work/caller-drift.yml"
run_hb "$all_fresh" "$work/caller-drift.yml"
assert_grep "a registry cron missing from the caller is caught" "never fires" "$(cat "$sum")"

# `grep -F '7 14 * * 3'` also matches '17 14 * * 3', so a one-digit drift used
# to pass the check that exists to catch exactly that.
sed 's/"7 14/"17 14/' "$caller_ok" >"$work/caller-shifted.yml"
run_hb "$all_fresh" "$work/caller-shifted.yml"
assert_grep "a one-digit cron drift is caught, not swallowed as a substring" \
  "7 14 * * 3\` is in the registry" "$(cat "$sum")"

run_hb "$all_fresh" "$caller_ok" '[{"number":99}]'
assert_grep "a healthy clock closes its own tracking issue" "STAGED: gh issue close 99" "$(cat "$sum")"

# The caller owns run-name, so a caller that forgets it makes every job read as
# missing. That is one fault, and reporting it per job would bury the cause
# under its own symptoms.
unnamed=$(jq -c -n --arg a "$(ago 600)" '[{display_title:"docs: fix a typo", created_at:$a, conclusion:"success", html_url:"u"}]')
run_hb "$unnamed" "$caller_ok"
assert_grep "a caller that does not set run-name is one fault, not four" "not setting" "$(cat "$sum")"
assert_no_grep "and no job is reported individually as missing" "no run found" "$(cat "$sum")"

# ---------------------------------------------------------------------------
group "a proposal must prove it looked"

# The failure mode: a token missing `issues: read` makes every gh call 403, the
# model honestly proposes nothing, and an empty proposal is also what a healthy
# backlog produces. Without this check nothing downstream can tell them apart.
run_apply dm-flow-sweep '{"summary":"all quiet","actions":[]}'
assert_eq "a proposal with no surveyed block fails" "1" "$rc"
assert_grep "it says there is no evidence it read anything" "surveyed" "$out"

run_apply dm-flow-sweep '{"summary":"all quiet","surveyed":{"items_read":0,"sources":["gh issue list -> 403"]},"actions":[]}'
assert_eq "a run that read zero items fails" "1" "$rc"
assert_grep "a blind run is not called a clean backlog" "blind run" "$out"

run_apply dm-flow-sweep '{"summary":"all quiet","surveyed":{"items_read":9,"sources":[]},"actions":[]}'
assert_eq "a surveyed block with no sources fails" "1" "$rc"

run_apply dm-flow-sweep '{"summary":"quiet","surveyed":{"items_read":31,"sources":["gh issue list","gh pr list"]},"actions":[]}'
assert_eq "a corroborated empty backlog succeeds" "0" "$rc"
assert_grep "the summary records what was read" "surveyed: 31 item(s)" "$(cat "$sum")"

# ---------------------------------------------------------------------------
group "refusing applies nothing, not the part that fit"

# Every one of these mixes a legal action with an illegal one. The legal action
# comes first, so a check that ran inside the apply loop would already have
# written it. Asserting on the write log rather than on the exit code is the
# whole point of this group.
first_ok='{"type":"comment","target":3,"why":"open 21d, last event 2026-08-05","body":"Stalled."}'

run_apply arch-drift-audit "$(proposal "$first_ok" \
  "$(action escalate 0 'D-002 vs pyproject.toml:14' '{"body":"needs superseding"}')")"
assert_eq "escalate with nowhere to go refuses" "1" "$rc"
assert_no_grep "and the legal comment before it is not applied" "STAGED" "$(cat "$sum")"
assert_eq "and nothing reached gh" "" "$(cat "$work/gh.log")"

run_apply dm-flow-sweep "$(jq -c -n --argjson a "$first_ok" \
  '{summary:"t",surveyed:{items_read:4,sources:["x"]},actions:[$a,{type:"merge-pr",target:3,why:"because"}]}')"
assert_eq "an unknown type refuses" "1" "$rc"
assert_no_grep "and the legal comment before it is not applied" "STAGED" "$(cat "$sum")"

run_apply dm-flow-sweep "$(jq -c -n --argjson a "$first_ok" \
  '{summary:"t",surveyed:{items_read:4,sources:["x"]},actions:[$a,{type:"label",target:3,why:"stale"}]}')"
assert_eq "a label action with no labels refuses instead of crashing mid-loop" "1" "$rc"
assert_grep "and names the missing field" "fields their type needs" "$out"
assert_no_grep "and applies nothing" "STAGED" "$(cat "$sum")"

run_apply dm-flow-sweep "$(jq -c -n --argjson a "$first_ok" \
  '{summary:"t",surveyed:{items_read:4,sources:["x"]},actions:[$a,{type:"comment",target:9,why:"y"}]}')"
assert_eq "a comment with no body refuses" "1" "$rc"

# ---------------------------------------------------------------------------
group "an event-scoped job is bound to the issue that triggered it"

# po-intake reads an issue body written by whoever opened it. "Not this run's
# job" in the brief is a prompt, not a boundary. This is the boundary.
ESC=99 ISSUE_UNDER_TEST=7 run_apply po-intake "$(proposal \
  "$(action comment 45 'the body of #7 asked for this' '{"body":"unblocking"}')")"
assert_eq "an action aimed at another issue refuses" "1" "$rc"
assert_grep "and names the issue it was scoped to" "scoped to issue #7" "$out"
assert_eq "and nothing reached gh" "" "$(cat "$work/gh.log")"

ESC=99 ISSUE_UNDER_TEST=7 run_apply po-intake "$(proposal \
  "$(action comment 7 'four-part test: 3 of 4' '{"body":"needs a definition of done"}')" \
  "$(action label 7 'same' '{"labels":["needs-detail"]}')")"
assert_eq "actions on its own issue apply" "0" "$rc"
assert_grep "the comment lands on the triggering issue" "issue comment 7" "$(cat "$sum")"

ESC=99 ISSUE_UNDER_TEST=7 run_apply po-intake "$(proposal \
  "$(action escalate 0 'duplicate of #12, closing is a decision' '{"body":"recommend closing #7"}')")"
assert_eq "an escalation with no issue of its own is still allowed" "0" "$rc"
assert_grep "and lands on the escalation issue" "issue comment 99" "$(cat "$sum")"

ISSUE_UNDER_TEST='' run_apply po-intake "$(proposal \
  "$(action comment 7 'x' '{"body":"y"}')")"
assert_eq "an event-scoped job with no ISSUE refuses" "1" "$rc"

# ---------------------------------------------------------------------------
group "project-field sends values as variables, never as query text"

export GH_FIELDS='[{"id":"F_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"O_ready","name":"Ready"}]},{"id":"F_size","name":"Size","dataType":"NUMBER"},{"id":"F_when","name":"Last-touched","dataType":"DATE"},{"id":"F_note","name":"Note","dataType":"TEXT"}]'

run_pf() {
  : >"$work/gh.log"
  out=$(ROLE_PROJECT_ID=P GH_LOG="$work/gh.log" \
        ROLE_PROJECT_TOKEN=t bash "$roles/bin/project-field.sh" "${PF_MODE:-apply}" konyklabs/roadmap 3 "$1" "$2" 2>&1); rc=$?
}

run_pf Size "1, x: 2"
assert_eq "a NUMBER field rejects a non-number" "1" "$rc"
assert_grep "and says what it wanted" "is a NUMBER" "$out"
assert_eq "and sends no mutation" "" "$(cat "$work/gh.log")"

run_pf Last-touched "2026-08-26; DROP"
assert_eq "a DATE field rejects a non-date" "1" "$rc"
assert_eq "and sends no mutation" "" "$(cat "$work/gh.log")"

run_pf Status "Nope"
assert_eq "an unknown single-select option is rejected" "1" "$rc"
assert_grep "and lists the ones that exist" "Ready" "$out"

run_pf Nonexistent "x"
assert_eq "an unknown field name is rejected" "1" "$rc"
assert_grep "and lists the fields that exist" "Status" "$out"

run_pf Note 'Blocked on "auth" }} }'
assert_eq "a text value full of GraphQL punctuation is accepted" "0" "$rc"
assert_grep "because it travels as a variable" 'text=Blocked on "auth" }} }' "$(cat "$work/gh.log")"
assert_no_grep "and never as query text" 'value: {text: Blocked' "$(cat "$work/gh.log")"

run_pf Size 42
assert_eq "a valid number is accepted" "0" "$rc"
unset GH_FIELDS

# ---------------------------------------------------------------------------
group "the write path, unstaged"

# Every other apply assertion runs staged, which means `gh_do` short-circuits
# before the real `gh` is ever reached — so the "nothing reached gh" assertions
# elsewhere only mean anything if this group proves the log is reachable at all.
STAGE=false run_apply dm-flow-sweep "$(proposal \
  "$(action comment 31 'open 21d, last event 2026-08-05' '{"body":"Stalled."}')" \
  "$(action label 31 'same' '{"labels":["stale"]}')")"
assert_eq "an unstaged run succeeds" "0" "$rc"
assert_grep "the comment really is issued" "WRITE: issue comment 31" "$(cat "$work/gh.log")"
assert_grep "the label really is issued" "WRITE: issue edit 31 --repo konyklabs/roadmap --add-label stale" "$(cat "$work/gh.log")"

STAGE=false ESC=99 run_apply arch-drift-audit "$(proposal \
  "$(action create-issue 0 'square and clover differ with no ADR' '{"title":"Spike: pick one mock transport","body":"b","labels":["spike"]}')")"
assert_eq "create-issue with target 0 is legal" "0" "$rc"
assert_grep "and is issued" "WRITE: issue create" "$(cat "$work/gh.log")"

# ---------------------------------------------------------------------------
group "an action that needs an issue number must have one"

# target 0 is schema-legal and right for create-issue and escalate. For anything
# else it is an issue number that is not an issue, and `gh issue comment 0`
# fails — mid-loop, after earlier actions have landed.
STAGE=false run_apply dm-flow-sweep "$(proposal \
  "$(action label 31 'stale since 2026-08-05' '{"labels":["stale"]}')" \
  "$(action comment 0 'WIP is at seven in-flight items' '{"body":"WIP 7"}')")"
assert_eq "a comment with target 0 refuses" "1" "$rc"
assert_grep "and says what is missing" "no issue number to act on" "$out"
assert_eq "and the legal label before it never reached gh" "" "$(cat "$work/gh.log")"

STAGE=false run_apply dm-flow-sweep "$(proposal \
  "$(action unlabel -3 'x' '{"labels":["stale"]}')")"
assert_eq "a negative target refuses" "1" "$rc"

# ---------------------------------------------------------------------------
group "staging covers the Project v2 path too"

export GH_FIELDS='[{"id":"F_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"O_ready","name":"Ready"}]}]'

PROJ=P PROJTOK=t ISSUE_UNDER_TEST=7 run_apply po-intake "$(proposal \
  "$(action set-field 7 'ready per the four-part test' '{"field":"Status","value":"Ready"}')")"
assert_eq "a staged set-field succeeds" "0" "$rc"
assert_grep "and says what it would have written" "STAGED: project-field #7 Status=Ready" "$(cat "$sum")"
assert_eq "and sends no mutation, not even the add-to-board one" "" "$(cat "$work/gh.log")"

PROJ=P PROJTOK=t ISSUE_UNDER_TEST=7 STAGE=false run_apply po-intake "$(proposal \
  "$(action set-field 7 'ready per the four-part test' '{"field":"Status","value":"Ready"}')")"
assert_eq "an unstaged set-field succeeds" "0" "$rc"
assert_grep "and does send the mutation" "WRITE: graphql" "$(cat "$work/gh.log")"

PROJ=P PROJTOK=t ISSUE_UNDER_TEST=7 run_apply po-intake "$(proposal \
  "$(action set-field 7 'x' '{"field":"Status","value":"Nope"}')")"
assert_eq "a staged set-field still validates the value" "1" "$rc"
unset GH_FIELDS

# ---------------------------------------------------------------------------
group "the board is checked before the first write, not during"

# Whether a SINGLE_SELECT option name is real is a fact only the board has.
# Checking it inside the loop meant a one-letter typo aborted the run after the
# comment before it had already been posted.
export GH_FIELDS='[{"id":"F_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"O_ready","name":"Ready"}]},{"id":"F_size","name":"Size","dataType":"NUMBER"}]'

PROJ=P PROJTOK=t STAGE=false run_apply arch-drift-audit "$(proposal \
  "$(action comment 31 'D-002 vs pyproject.toml:14' '{"body":"drifted"}')" \
  "$(action set-field 31 'same' '{"field":"Status","value":"Redy"}')")"
assert_eq "a set-field the board rejects refuses the whole proposal" "1" "$rc"
assert_grep "and says which action" "set-field the board rejects" "$out"
assert_eq "and the legal comment before it never reached gh" "" "$(cat "$work/gh.log")"

PROJ=P PROJTOK=t STAGE=false run_apply arch-drift-audit "$(proposal \
  "$(action comment 31 'x' '{"body":"y"}')" \
  "$(action set-field 31 'same' '{"field":"Size","value":"large"}')")"
assert_eq "a NUMBER field with a word refuses before writing" "1" "$rc"
assert_eq "and nothing reached gh" "" "$(cat "$work/gh.log")"

PROJ=P PROJTOK=t STAGE=false run_apply arch-drift-audit "$(proposal \
  "$(action comment 31 'x' '{"body":"y"}')" \
  "$(action set-field 31 'same' '{"field":"Status","value":"Ready"}')")"
assert_eq "a valid pair applies" "0" "$rc"
assert_grep "the comment lands" "WRITE: issue comment 31" "$(cat "$work/gh.log")"
assert_grep "and so does the field" "WRITE: graphql" "$(cat "$work/gh.log")"

PF_MODE=check run_pf Status Ready
assert_eq "check mode succeeds on a valid value" "0" "$rc"
assert_eq "and writes nothing" "" "$(cat "$work/gh.log")"

PF_MODE=check run_pf Status Redy
assert_eq "check mode fails on an invalid option" "1" "$rc"

# apply.sh's board gate should stop this being reachable, but the guard is the
# thing that makes the token's scope a property of the script rather than of the
# caller, so it gets its own assertion.
: >"$work/gh.log"
out=$(ROLE_PROJECT_ID=P ROLE_PROJECT_TOKEN='' GH_LOG="$work/gh.log" \
      bash "$roles/bin/project-field.sh" check konyklabs/roadmap 3 Status Ready 2>&1); rc=$?
assert_eq "project-field refuses to run without its own token" "1" "$rc"
assert_grep "and names it" "ROLE_PROJECT_TOKEN" "$out"
unset GH_FIELDS

# ---------------------------------------------------------------------------
group "a half-configured board skips itself, it does not fail the proposal"

# The variable and the secret live on different configuration surfaces, so
# setting one without the other is the ordinary way to arrive here. Before this,
# the board pre-check ran on the variable alone, GITHUB_TOKEN cannot read
# Projects v2, and the resulting refusal killed every comment and label in the
# same proposal — an unconfigured board reading downstream as a failed role.
export GH_FIELDS='[{"id":"F_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"O_ready","name":"Ready"}]}]'

PROJ=P STAGE=false run_apply arch-drift-audit "$(proposal \
  "$(action comment 31 'D-002 vs pyproject.toml:14' '{"body":"drifted"}')" \
  "$(action set-field 31 'same' '{"field":"Status","value":"Ready"}')")"
assert_eq "id without token: the proposal still applies" "0" "$rc"
assert_grep "the comment lands" "WRITE: issue comment 31" "$(cat "$work/gh.log")"
assert_grep "the set-field is skipped and named" "SKIPPED set-field" "$(cat "$sum")"
assert_grep "and says which setting is missing" "no ROLE_PROJECT_TOKEN" "$(cat "$sum")"
assert_no_grep "and no board call is made" "graphql" "$(cat "$work/gh.log")"

PROJTOK=t STAGE=false run_apply arch-drift-audit "$(proposal \
  "$(action set-field 31 'x' '{"field":"Status","value":"Ready"}')")"
assert_eq "token without id: also skipped, not refused" "0" "$rc"
assert_grep "and says which setting is missing" "no ROLE_PROJECT_ID" "$(cat "$sum")"
unset GH_FIELDS

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
