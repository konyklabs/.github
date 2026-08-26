#!/usr/bin/env bash
# Merge every lens's findings into one attribution-free list for the judge.
#
# Reviewers run as a matrix, and matrix jobs cannot each set a job output —
# they overwrite one another. Each lens therefore uploads findings-<lens>.json
# as an artifact and this script merges the downloaded directory.
#
# Attribution is stripped on purpose. The judge must score a finding on its
# evidence, not on which model produced it; leaving the lens name attached
# invites deference to the stronger model. Sorting by (path, line, title) also
# breaks up the per-lens grouping that ordering alone would leak.
#
# Usage: merge-findings.sh <findings-dir> <out-merged.json> <out-provenance.json>
set -euo pipefail

dir=${1:?findings dir}
out=${2:?merged output path}
prov=${3:?provenance output path}

shopt -s nullglob
files=("$dir"/findings-*.json)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo '{"findings":[]}' >"$out"
  echo '[]' >"$prov"
  echo "merge: no lens findings files in $dir" >&2
  exit 0
fi

# Tag each finding with its lens while merging, sort into an attribution-free
# order, assign opaque ids, then split into (judge input) and (run-log record).
jq -s '
  [ .[] as $doc
    | ($doc.lens // "unknown") as $lens
    | ($doc.findings // [])[]
    | . + {lens: $lens}
  ]
  | sort_by(.path, .line, (.title | ascii_downcase))
  | to_entries
  | map(.value + {id: ("f" + ((.key + 1) | tostring))})
' "${files[@]}" >"$dir/.tagged.json"

jq '{findings: map(del(.lens))}' "$dir/.tagged.json" >"$out"
jq 'map({id, lens, path, line, severity, title})' "$dir/.tagged.json" >"$prov"

echo "merge: $(jq '.findings | length' "$out") findings from ${#files[@]} lens file(s)" >&2
