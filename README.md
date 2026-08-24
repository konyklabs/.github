# .github

Org-wide defaults for konyklabs.

## Commit & release standard

- Squash merges only — the PR title becomes the commit subject on main.
- Titles: conventional commits (`type(scope): imperative subject`) **and** a
  task reference (`#N` / `org/repo#N`). Enforced by `workflows/title-lint.yml`;
  release PRs are exempt. No task? File one in `konyklabs/roadmap` first.
- Versioning: `workflows/release-please.yml` (reusable) — callers pass
  `release-type`; release PRs merge like any other change.

- `workflows/claude-review.yml` — reusable Claude PR review (subscription
  OAuth token via the `CLAUDE_CODE_OAUTH_TOKEN` org secret; no API billing).
  Consume from any repo with:

  ```yaml
  jobs:
    review:
      uses: konyklabs/.github/.github/workflows/claude-review.yml@main
      secrets: inherit
  ```

## The review loop

1. Open a PR → CI builds, Claude reviews and submits a formal verdict
   (approve or request-changes). Branch rulesets require one approving
   review, so a PR with a request-changes verdict cannot merge.
2. To iterate on a blocked PR, comment:
   `@claude address the review feedback and push fixes` — the assistant
   workflow pushes commits to the branch.
3. Every push dismisses stale reviews and re-triggers the review, closing
   the loop. Repo admins can bypass the ruleset in an emergency (the
   bypass is explicit and logged in the UI).
