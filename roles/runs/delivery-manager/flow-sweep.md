# Run: flow sweep

Nightly. Find work that has stopped moving, and records that do not join up.

## Do

1. Open issues: `gh issue list --repo $REPO --state open --limit 200 --json number,title,labels,updatedAt,comments`
2. Read `.roles-context/context.json`. If `mode` is `single-repo`, note it in
   `surveyed.sources` and in `unresolved`, and work from this repo alone — do
   not report an org-wide number you could not compute. Otherwise, for each repo
   in `repos`, read `.roles-context/pulls-<r>.json` and `branches-<r>.json`.
3. `gh run list --repo $REPO --limit 20` for this repository's own checks.
4. Compute, do not estimate:
   - **WIP**: issues in flight (`build` and not `blocked`) plus open non-draft PRs.
   - **Stale**: open, no comment and no linked PR activity in 10 days. Report the exact days and the last real event.
   - **Blocked without a blocker**: labelled `blocked` with nothing named in the last comment. That is a stall, and it is worse than being blocked.
   - **Chain breaks**: a PR whose title carries no `#N`; a branch with no matching issue number; a merged PR whose issue is still open; an ADR in `decisions/` with no build issue referencing it.
   - **Red and unattended**: a required check failing for more than 24h with no push since.
5. Before proposing a comment, check the issue's recent comments for the `konyklabs-role` footer. If a previous sweep already said this, say nothing.

## Output

- `comment` on at most the four most costly items, each naming the days, the last event, and the one action that unsticks it.
- `label` `stale` / `blocked` where the evidence supports it, `unlabel` where it no longer does.
- `set-field` Status and Last-touched.
- `escalate` if WIP exceeds five in-flight items, or if a chain break cannot be attributed.

## Not this run's job

- Priority, scope or whether something should exist. Put it in `unresolved` for the product owner.
- Commenting on a healthy backlog. Zero actions is the expected result most nights.

## Done

Every stalled item that is worth a human's attention tonight has exactly one
comment; WIP, staleness and chain breaks are numbers; nothing is repeated from
a previous sweep.
