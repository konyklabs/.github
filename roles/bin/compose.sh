#!/usr/bin/env bash
# Build one role job's prompt from files, never from the workflow.
#
# The prompt is charter + run brief + shared ground rules, concatenated in that
# order. Nothing about what a role may do lives in YAML: the workflow passes a
# registry id and this script resolves everything else, so the blast radius of a
# job is a reviewed diff in registry.json rather than an argument someone edited
# in a caller.
#
# Budget — model, effort, turn cap — also comes from the registry, for the same
# reason the review matrix does: a role cannot vote itself more compute.
#
# Reads $JOB (a registry id) plus $REPO, $ISSUE, $RUN_URL. Writes step outputs:
#   prompt, schema, model, effort, max_turns, role, brief, repo
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

job=${JOB:?job id}
registry="$here/registry.json"

entry=$(jq -c --arg id "$job" '.jobs[] | select(.id == $id)' "$registry")
if [ -z "$entry" ]; then
  echo "::error::No job '$job' in roles/registry.json. A job that is not in the registry does not exist."
  exit 1
fi

role=$(jq -r '.role' <<<"$entry")
brief=$(jq -r '.brief' <<<"$entry")
repo=${REPO:-$(jq -r '.repo' <<<"$entry")}

charter="$here/agents/$role.md"
runbrief="$here/runs/$role/$brief.md"
for f in "$charter" "$runbrief" "$here/agents/_shared.md"; do
  [ -f "$f" ] || { echo "::error::Missing $f"; exit 1; }
done

caps=$(jq -c '.caps' <<<"$entry")
labels=$(jq -c '.labels.allowed' "$registry")

body=$(mktemp)
{
  echo "# Context"
  echo
  echo "- repository: \`$repo\`"
  echo "- job: \`$job\` (role \`$role\`, brief \`$brief\`)"
  [ -n "${ISSUE:-}" ] && echo "- issue under intake: #$ISSUE"
  echo "- this run: ${RUN_URL:-unknown}"
  echo "- cross-repo context: \`.roles-context/\` — read it with Read/Grep, not with \`gh\`."
  echo "  \`context.json\` says \`org\` or \`single-repo\`; in single-repo mode only this"
  echo "  repository is visible and you must say so in \`surveyed.sources\` and \`unresolved\`."
  echo "  Per repo: \`issues-<repo>.json\`, \`pulls-<repo>.json\`, \`branches-<repo>.json\`."
  echo "- caps for this run, enforced after you finish: \`$caps\`"
  scope=$(jq -r '.scope // "repo"' <<<"$entry")
  if [ "$scope" = "triggering-issue" ]; then
    echo "- scope: **issue #${ISSUE:-?} only**. An action targeting any other issue fails the entire run, including the actions that were fine."
  fi
  echo "- labels you may use: \`$labels\`"
  echo "- footer marker on anything a role already posted: \`<!-- $(jq -r '.footer' "$registry"): \`"
  echo
  cat "$here/agents/_shared.md"
  echo
  echo "# Your charter"
  echo
  # Strip the subagent frontmatter: in CI the body is the whole contract.
  # awk, not sed, because BSD sed rejects the one-liner form of this and the
  # tests are meant to run on the laptop as well as on the runner.
  awk 'NR==1 && $0 != "---" { all=1 }
       all { print; next }
       /^---$/ { fm++; next }
       fm >= 2 { print }' "$charter"
  echo
  echo "# This run"
  echo
  sed -e "s|\$ISSUE|${ISSUE:-}|g" -e "s|\$REPO|$repo|g" "$runbrief"
  echo
  echo "Return JSON matching the schema you were given. Every action needs a"
  echo "\`why\` citing what you read. An empty \`actions\` array is a valid result."
} >"$body"

delim="ROLE_$(sha256sum "$body" | cut -c1-32)"
{
  echo "role=$role"
  echo "brief=$brief"
  echo "repo=$repo"
  echo "model=$(jq -r '.model' <<<"$entry")"
  echo "effort=$(jq -r '.effort' <<<"$entry")"
  echo "max_turns=$(jq -r '.max_turns' <<<"$entry")"
  echo "schema=$(jq -c . "$here/schemas/proposal.json")"
  echo "prompt<<$delim"
  cat "$body"
  echo "$delim"
} >>"$out"

{
  echo "### Role job \`$job\`"
  echo
  echo "- role: \`$role\` · brief: \`$brief\` · repo: \`$repo\`"
  echo "- budget: $(jq -c '{model, effort, max_turns}' <<<"$entry")"
  echo "- caps: \`$caps\`"
} >>"$summary"

echo "compose: job=$job role=$role brief=$brief repo=$repo" >&2
