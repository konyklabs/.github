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
proposal() { jq -c -n --argjson a "$(jq -sc '.' <<<"$*")" '{summary: "test", actions: $a}'; }

# run_apply <job> <proposal-json>  -> sets $out (stdout+stderr), $rc, $sum (step summary)
run_apply() {
  sum="$work/summary.md"; : >"$sum"
  out=$(RAW="$2" JOB="$1" REPO="konyklabs/roadmap" RUN_URL="test" ROLE_STAGE=true \
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

run_apply dm-flow-sweep "$(jq -c -n '{summary:"nothing to do",actions:[],unresolved:["priority is the product owner ground"]}')"
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

sum="$work/summary.md"; : >"$sum"
out=$(RAW="$(proposal "$(action set-field 3 'ready per the four-part test' '{"field":"Status","value":"Ready"}')")" \
      JOB=po-intake REPO=konyklabs/roadmap RUN_URL=test ROLE_STAGE=true \
      GITHUB_STEP_SUMMARY="$sum" bash "$roles/bin/apply.sh" 2>&1); rc=$?
assert_eq "set-field with no board configured still succeeds" "0" "$rc"
assert_grep "set-field with no board is named, not dropped" "SKIPPED set-field" "$(cat "$sum")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
