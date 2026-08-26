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

## Roles and the clock

`roles/` carries the org's governance roles — `product-owner`,
`delivery-manager`, `architect` — as one file each that is simultaneously the
Claude Code subagent and the charter its unattended job runs from. See
[roles/README.md](roles/README.md) for the model and the admission test for a
new role.

Two reusable workflows drive them:

```yaml
jobs:
  role:
    uses: konyklabs/.github/.github/workflows/role-job.yml@main
    with:
      job: dm-flow-sweep          # an id from roles/registry.json
    secrets: inherit
```

```yaml
jobs:
  heartbeat:
    uses: konyklabs/.github/.github/workflows/role-heartbeat.yml@main
    secrets: inherit
```

`role-job` runs the model with `contents: read` and no write scope, then applies
its JSON proposal from a second job that has the write scopes and no model in
it. Caps live in `roles/registry.json`, so widening what a role may do is a
reviewable diff.

To get the same roles in an interactive session, add to a repo's
`.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "konyklabs": { "source": { "source": "github", "repo": "konyklabs/.github" } }
  },
  "enabledPlugins": { "roles@konyklabs": true }
}
```
