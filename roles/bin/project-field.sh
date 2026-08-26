#!/usr/bin/env bash
# Set one Project v2 field on one issue.
#
# Split out of apply.sh because it is the only write here that needs GraphQL and
# a token with project scope, and because a board that is not configured yet
# must not take the rest of a role's output down with it.
#
# Usage: project-field.sh <repo> <issue> <field> <value>
# Requires: $ROLE_PROJECT_ID, and a $GH_TOKEN carrying `project`.
set -euo pipefail


repo=${1:?repo}; issue=${2:?issue}; field=${3:?field}; value=${4:?value}
project=${ROLE_PROJECT_ID:?ROLE_PROJECT_ID}

content=$(gh api "/repos/$repo/issues/$issue" --jq '.node_id')

# GraphQL variables are $-prefixed and must reach the server unexpanded.
# shellcheck disable=SC2016
item=$(gh api graphql -f projectId="$project" -f contentId="$content" -f query='
  mutation($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
      item { id }
    }
  }' --jq '.data.addProjectV2ItemById.item.id')

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

case "$dtype" in
  SINGLE_SELECT)
    oid=$(jq -r --arg n "$field" --arg v "$value" \
      '.[] | select(.name == $n) | .options[] | select(.name == $v) | .id' <<<"$fields")
    if [ -z "$oid" ]; then
      echo "::error::Field '$field' has no option '$value'. Known: $(jq -r --arg n "$field" '.[] | select(.name == $n) | [.options[].name] | join(", ")' <<<"$fields")"
      exit 1
    fi
    val="{singleSelectOptionId: \"$oid\"}" ;;
  NUMBER) val="{number: $value}" ;;
  DATE)   val="{date: \"$value\"}" ;;
  *)      val="{text: \"$value\"}" ;;
esac

gh api graphql -f projectId="$project" -f itemId="$item" -f fieldId="$fid" -f query="
  mutation(\$projectId: ID!, \$itemId: ID!, \$fieldId: ID!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: \$projectId, itemId: \$itemId, fieldId: \$fieldId, value: $val
    }) { projectV2Item { id } }
  }" >/dev/null

echo "project-field: #$issue $field=$value" >&2
