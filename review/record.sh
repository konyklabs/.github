#!/usr/bin/env bash
# Persist one job's structured output as an artifact payload.
#
# Matrix jobs cannot each set a job output — they overwrite one another — so
# every lens writes a file and uploads it, and later jobs read the directory.
# A job that produced nothing usable fails here rather than silently
# contributing an empty result, because an empty result is indistinguishable
# from a clean review and that difference is the whole point of the gate.
#
# Usage: record.sh <findings|verdicts>
set -euo pipefail

mode=${1:?mode}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
mkdir -p out

case "$mode" in
  findings)
    : "${LENS:?}"
    if [ -z "${RAW:-}" ] || ! jq -e '.findings | type == "array"' >/dev/null 2>&1 <<<"$RAW"; then
      echo "::error::Lens $LENS returned no structured findings. Re-run; this is not a rejection."
      exit 1
    fi
    jq --arg lens "$LENS" '{lens: $lens, findings: .findings}' <<<"$RAW" \
      >"out/findings-$LENS.json"
    n=$(jq '.findings | length' "out/findings-$LENS.json")
    echo "- \`$LENS\`: $n raw finding(s)" >>"$summary"
    echo "record: lens=$LENS findings=$n" >&2
    ;;

  verdicts)
    if [ "${COUNT:-0}" = "0" ]; then
      echo '{"verdicts":[]}' >out/verdicts.json
      echo "- judge: no findings to score" >>"$summary"
      echo "record: judge skipped, no findings" >&2
      exit 0
    fi
    if [ -z "${RAW:-}" ] || ! jq -e '.verdicts | type == "array"' >/dev/null 2>&1 <<<"$RAW"; then
      echo "::error::Judge returned no structured verdicts. Re-run; this is not a rejection."
      exit 1
    fi
    jq '{verdicts: .verdicts}' <<<"$RAW" >out/verdicts.json
    {
      echo "### Judge"
      echo
      echo "| id | confidence | severity | duplicate of |"
      echo "|---|---|---|---|"
      jq -r '.verdicts[] | "| \(.id) | \(.confidence) | \(.severity) | \(.duplicate_of // "—") |"' \
        out/verdicts.json
    } >>"$summary"
    echo "record: verdicts=$(jq '.verdicts | length' out/verdicts.json)" >&2
    ;;

  *)
    echo "record: unknown mode '$mode'" >&2
    exit 2
    ;;
esac
