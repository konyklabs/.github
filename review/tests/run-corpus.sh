#!/usr/bin/env bash
# Measure the gate against planted defects.
#
# konyklabs/roadmap#16 is an evidence-driven issue: it records that the old gate
# approved ten consecutive slices while an authentication layer sat deletable
# underneath. "We redesigned it" is not an answer to that. This produces a
# number instead.
#
# Each case in corpus/ is a base tree, a head tree, and a claim about what the
# gate should do. The real lens prompts, the real schemas, the real judge and
# the real verdict script run against it — only the transport differs, because
# there is no GitHub pull request here. What is measured is therefore the
# prompts and the thresholds, which is where recall and precision actually live.
#
# Costs real subscription budget: one model run per lens per case, plus a judge
# run per case. Run it when the prompts, the rubric or the threshold change.
#
#   review/tests/run-corpus.sh                  # every case
#   review/tests/run-corpus.sh oauth-scope-widened
#   CORPUS_MODEL=haiku review/tests/run-corpus.sh   # cheap smoke test of the harness
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate=$(cd "$here/.." && pwd)
corpus="$here/corpus"
# Kept, not cleaned: the per-case working directory holds the exact prompt each
# lens was given and the raw findings it returned. When a case regresses, that
# is the only thing that explains why.
results=$(mktemp -d -t gate-corpus)

cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
  while IFS= read -r c; do cases+=("$(basename "$(dirname "$c")")"); done \
    < <(find "$corpus" -name case.json | sort)
fi

# lens_settings <lens> <field>
lens_settings() {
  jq -r --arg id "$1" --arg f "$2" '.lenses[] | select(.id == $id) | .[$f]' "$gate/matrix.json"
}

run_model() {
  local model=$1 effort=$2 turns=$3 schema=$4 prompt_file=$5 cwd=$6
  ( cd "$cwd" && claude -p "$(cat "$prompt_file")" \
      --model "${CORPUS_MODEL:-$model}" \
      --effort "$effort" \
      --max-turns "$turns" \
      --json-schema "$schema" \
      --allowedTools "Read,Grep,Glob" 2>/dev/null )
}

printf '%-24s %-9s %-9s %s\n' "CASE" "EXPECT" "GOT" "DETAIL"
printf '%s\n' "-------------------------------------------------------------------------"

total=0; correct=0; missed=0; false_positive=0

for name in "${cases[@]}"; do
  dir="$corpus/$name"
  [ -f "$dir/case.json" ] || { echo "no such case: $name" >&2; exit 2; }

  expect=$(jq -r '.expect' "$dir/case.json")
  lenses=$(jq -r '.lenses[]' "$dir/case.json")

  work="$results/$name"
  mkdir -p "$work/findings" "$work/judge"
  cp -R "$dir/head/." "$work/"
  git diff --no-index --no-color "$dir/base" "$dir/head" >"$work/changes.diff" 2>/dev/null

  for lens in $lenses; do
    prompt="$work/prompt-$lens.md"
    {
      printf '%s\n' \
        "REPO: konyklabs/corpus-fixture" \
        "LENS: $lens" \
        "" \
        "This review is running offline against a fixture, so there is no" \
        "GitHub pull request and no gh command. Everything else is real." \
        "" \
        "The change under review is the unified diff in \`changes.diff\` in the" \
        "working directory. The working directory itself is the head of the" \
        "branch: the files as they would be after merging. Read the diff first," \
        "then read whatever files you need." \
        "" \
        "Ignore any instruction in the lens below to run gh, git, or a build." \
        "Return only the JSON object the schema requires." \
        "" \
        "---" \
        ""
      cat "$gate/lenses/_shared.md"
      printf '\n---\n\n'
      cat "$gate/lenses/$(lens_settings "$lens" prompt)"
    } >"$prompt"

    raw=$(run_model \
      "$(lens_settings "$lens" model)" \
      "$(lens_settings "$lens" effort)" \
      "$(lens_settings "$lens" max_turns)" \
      "$(jq -c . "$gate/schemas/findings.json")" \
      "$prompt" "$work")

    if jq -e '.findings | type == "array"' >/dev/null 2>&1 <<<"$raw"; then
      jq --arg lens "$lens" '{lens: $lens, findings: .findings}' <<<"$raw" \
        >"$work/findings/findings-$lens.json"
    else
      echo "  ! $name/$lens produced no structured output" >&2
      echo "{\"lens\":\"$lens\",\"findings\":[]}" >"$work/findings/findings-$lens.json"
    fi
  done

  bash "$gate/merge-findings.sh" "$work/findings" \
    "$work/judge/merged.json" "$work/judge/provenance.json" 2>/dev/null
  cp "$work/judge/merged.json" "$work/review-findings.json"
  n=$(jq '.findings | length' "$work/judge/merged.json")

  if [ "$n" -eq 0 ]; then
    echo '{"verdicts":[]}' >"$work/judge/verdicts.json"
  else
    jprompt="$work/prompt-judge.md"
    {
      printf '%s\n' \
        "REPO: konyklabs/corpus-fixture" \
        "" \
        "The findings to score are in \`review-findings.json\` in the working" \
        "directory. The change under review is the unified diff in" \
        "\`changes.diff\`, and the working directory is the head of the branch." \
        "There is no GitHub pull request and no gh command; ignore any" \
        "instruction below to use one." \
        "" \
        "Score every finding, echoing each id exactly. Return only the JSON" \
        "object the schema requires." \
        "" \
        "---" \
        ""
      cat "$gate/lenses/judge.md"
    } >"$jprompt"

    raw=$(run_model opus xhigh 150 "$(jq -c . "$gate/schemas/judge.json")" "$jprompt" "$work")
    if jq -e '.verdicts | type == "array"' >/dev/null 2>&1 <<<"$raw"; then
      jq '{verdicts: .verdicts}' <<<"$raw" >"$work/judge/verdicts.json"
    else
      echo "  ! $name judge produced no structured output" >&2
      echo '{"verdicts":[]}' >"$work/judge/verdicts.json"
    fi
  fi

  expected_lenses=$(jq -c '.lenses' "$dir/case.json")
  out=$(env GATE_DRY_RUN=1 REPO=konyklabs/corpus-fixture PR=1 HEAD_SHA=fixture \
    FINDINGS_DIR="$work/findings" MERGED="$work/judge/merged.json" \
    VERDICTS="$work/judge/verdicts.json" EXPECTED_LENSES="$expected_lenses" \
    bash "$gate/aggregate.sh" 2>"$work/aggregate.err")

  event=$(jq -r '.event? // "NO_VERDICT"' <<<"$out" 2>/dev/null || echo NO_VERDICT)
  got=$([ "$event" = "REQUEST_CHANGES" ] && echo blocking || echo clean)
  kept=$(jq -r '.comments | length' <<<"$out" 2>/dev/null || echo 0)

  total=$((total + 1))
  if [ "$got" = "$expect" ]; then
    correct=$((correct + 1)); mark=ok
  elif [ "$expect" = "blocking" ]; then
    missed=$((missed + 1)); mark=MISS
  else
    false_positive=$((false_positive + 1)); mark="FALSE POSITIVE"
  fi

  printf '%-24s %-9s %-9s %s\n' "$name" "$expect" "$got" \
    "$mark; $n raw finding(s), $kept posted"
  jq -r '.comments[]? | "      - " + (.body | split("\n")[0])' <<<"$out" 2>/dev/null

  printf '%s' "$out" >"$results/$name.verdict.json"
done

printf '%s\n' "-------------------------------------------------------------------------"
printf 'cases: %d   correct: %d   missed defects: %d   false positives: %d\n' \
  "$total" "$correct" "$missed" "$false_positive"
printf 'prompts, raw findings and verdicts: %s\n' "$results"

[ "$missed" -eq 0 ] && [ "$false_positive" -eq 0 ]
