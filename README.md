# .github

Org-wide defaults for konyklabs.

- `workflows/claude-review.yml` — reusable Claude PR review (subscription
  OAuth token via the `CLAUDE_CODE_OAUTH_TOKEN` org secret; no API billing).
  Consume from any repo with:

  ```yaml
  jobs:
    review:
      uses: konyklabs/.github/.github/workflows/claude-review.yml@main
      secrets: inherit
  ```
