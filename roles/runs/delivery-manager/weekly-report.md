# Run: weekly report

Friday. One comment on the standing report issue, whose number is in your
context block — you do not have to work out which issue that is, and an action
aimed anywhere else fails the whole run. This is the only artifact of the week
that Oleg is guaranteed to read, so it is written to be read in one minute and
not opened twice.

## Do

1. Everything the flow sweep collects, over the last seven days.
2. Add movement from the same files, not from `gh` — you have no cross-repo
   `gh` and that is deliberate. `.roles-context/pulls-<r>.json` carries
   `merged_at` for every pull request in each repository, so the week's shipped
   work is the entries whose `merged_at` falls in the last seven days. Issues
   closed in the window come from this repository, where `gh` does work.
3. Add the clock's own health: `gh run list --repo $REPO --limit 100 --json displayTitle,conclusion,createdAt` and report, per registry job id, whether it ran and whether it succeeded. A role that did not run is the most important line in this report.

## Output

One `comment`, in this order and no other:

1. **Shipped** — merged PRs and closed issues, by repo, one line each.
2. **In flight** — WIP count, and each item with its days since last movement.
3. **Stuck** — stalled, blocked-without-blocker, red-and-unattended.
4. **Chain** — breaks found, or the word none.
5. **Clock** — every registry job, ran or did not, succeeded or did not.
6. **Needs Oleg** — the escalations of the week, gathered, each one line.

No preamble, no closing summary, no adjectives where a number exists.

## Not this run's job

- Any label, field or issue change. This run reports; the sweep acts.
- Congratulation, encouragement or narrative.

## Done

One comment posted, six sections, every claim a number or a link.
