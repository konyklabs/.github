#!/usr/bin/env bash
# Validate or set one Project v2 field on one issue.
#
# Two modes, because the board is the only boundary apply.sh cannot check
# locally — whether a field exists, and whether a SINGLE_SELECT option name is
# real, are facts only the board has. Validating inside the apply loop meant a
# value the board rejects aborted the run after earlier actions had already been
# posted, which is the partial apply the design says cannot happen. So:
#
#   check <repo> <issue> <field> <value>   validate only, write nothing
#   apply <repo> <issue> <field> <value>   validate, then write
#
# apply.sh runs `check` on every set-field action before its first write, and
# `apply` inside the loop. One implementation, so the two cannot drift.
#
# The board is read once: set ROLE_FIELDS_CACHE to a writable path and the first
# call fetches, the rest read the file.
#
# This is the one write path under a PAT that the apply job's `permissions:`
# block does not bound, so nothing model-authored is concatenated into a query —
# every dynamic part is a typed GraphQL variable, and the two scalar types are
# validated before they are sent.
#
# Requires: $ROLE_PROJECT_ID, and for `apply`, a $GH_TOKEN carrying `project`.
# Optional: $ROLE_STAGE (true = print what `apply` would write, write nothing).
set -euo pipefail

mode=${1:?mode: check|apply}; repo=${2:?repo}; issue=${3:?issue}
field=${4:?field}; value=${5:?value}
project=${ROLE_PROJECT_ID:?ROLE_PROJECT_ID}
stage=${ROLE_STAGE:-false}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
cache=${ROLE_FIELDS_CACHE:-}

fetch_fields() {
  # GraphQL variables are $-prefixed and must reach the server unexpanded.
  # shellcheck disable=SC2016
  gh api graphql -f projectId="$project" -f query='
    query($projectId: ID!) {
      node(id: $projectId) {
        ... on ProjectV2 {
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon { id name dataType }
              ... on ProjectV2SingleSelectField { id name dataType options { id name } }
            }
          }
        }
      }
    }' --jq '.data.node.fields.nodes'
}

if [ -n "$cache" ] && [ -s "$cache" ]; then
  fields=$(cat "$cache")
else
  fields=$(fetch_fields)
  [ -n "$cache" ] && printf '%s' "$fields" >"$cache"
fi

fid=$(jq -r --arg n "$field" '.[] | select(.name == $n) | .id' <<<"$fields")
if [ -z "$fid" ]; then
  echo "::error::Project has no field '$field'. Known: $(jq -r '[.[].name] | join(", ")' <<<"$fields")"
  exit 1
fi
dtype=$(jq -r --arg n "$field" '.[] | select(.name == $n) | .dataType' <<<"$fields")

# One document per value type, each with the value as a typed variable. There is
# no branch here in which model output becomes query text.
# shellcheck disable=SC2016
case "$dtype" in
  SINGLE_SELECT)
    oid=$(jq -r --arg n "$field" --arg v "$value" \
      '.[] | select(.name == $n) | .options[] | select(.name == $v) | .id' <<<"$fields")
    if [ -z "$oid" ]; then
      echo "::error::Field '$field' has no option '$value'. Known: $(jq -r --arg n "$field" '.[] | select(.name == $n) | [.options[].name] | join(", ")' <<<"$fields")"
      exit 1
    fi
    set -- -f optionId="$oid" -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
        updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId,
          fieldId: $fieldId, value: {singleSelectOptionId: $optionId}}) { projectV2Item { id } } }' ;;
  NUMBER)
    if ! [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
      echo "::error::Field '$field' is a NUMBER but the value was '$value'"
      exit 1
    fi
    set -- -F number="$value" -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $number: Float!) {
        updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId,
          fieldId: $fieldId, value: {number: $number}}) { projectV2Item { id } } }' ;;
  DATE)
    if ! [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "::error::Field '$field' is a DATE but the value was '$value' (want YYYY-MM-DD)"
      exit 1
    fi
    set -- -f date="$value" -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $date: Date!) {
        updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId,
          fieldId: $fieldId, value: {date: $date}}) { projectV2Item { id } } }' ;;
  *)
    set -- -f text="$value" -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $text: String!) {
        updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId,
          fieldId: $fieldId, value: {text: $text}}) { projectV2Item { id } } }' ;;
esac

if [ "$mode" = "check" ]; then
  echo "project-field: OK #$issue $field=$value ($dtype)" >&2
  exit 0
fi

if [ "$stage" = "true" ]; then
  printf 'STAGED: project-field #%s %s=%s (%s)\n' "$issue" "$field" "$value" "$dtype" >>"$summary"
  echo "project-field: STAGED #$issue $field=$value ($dtype)" >&2
  exit 0
fi

content=$(gh api "/repos/$repo/issues/$issue" --jq '.node_id')

# shellcheck disable=SC2016
item=$(gh api graphql -f projectId="$project" -f contentId="$content" -f query='
  mutation($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
      item { id }
    }
  }' --jq '.data.addProjectV2ItemById.item.id')

gh api graphql -f projectId="$project" -f itemId="$item" -f fieldId="$fid" "$@" >/dev/null

echo "project-field: #$issue $field=$value ($dtype)" >&2
