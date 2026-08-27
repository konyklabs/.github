#!/usr/bin/env bash
# Set one Project v2 field on one issue.
#
# Split out of apply.sh because it is the only write here that needs GraphQL and
# a token carrying `project` — a PAT, which is NOT bounded by the apply job's
# `permissions:` block. That makes it the one path where "the model cannot
# write" rests on this file rather than on the platform, so nothing
# model-authored is ever concatenated into a query document.
#
# `value` comes straight from model output. An earlier revision spliced it into
# the mutation text, where `Blocked on "auth"` was a syntax error and the NUMBER
# arm was not quoted at all. Every dynamic part is now a typed GraphQL variable,
# and the two scalar types are validated before they are sent.
#
# `field` and the single-select option are matched against what the server
# reports, so an unknown name fails with the known list rather than guessing.
#
# Order matters: read and validate first, mutate last. `addProjectV2ItemById` is
# itself a mutation — it puts the issue on the board — so it must not run before
# the value has been checked, and must not run at all under ROLE_STAGE.
#
# Usage: project-field.sh <repo> <issue> <field> <value>
# Requires: $ROLE_PROJECT_ID, and a $GH_TOKEN carrying `project`.
# Optional: $ROLE_STAGE (true = print what would be written, write nothing).
set -euo pipefail

repo=${1:?repo}; issue=${2:?issue}; field=${3:?field}; value=${4:?value}
project=${ROLE_PROJECT_ID:?ROLE_PROJECT_ID}
stage=${ROLE_STAGE:-false}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

# GraphQL variables are $-prefixed and must reach the server unexpanded.
# shellcheck disable=SC2016
fields=$(gh api graphql -f projectId="$project" -f query='
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
  }' --jq '.data.node.fields.nodes')

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
