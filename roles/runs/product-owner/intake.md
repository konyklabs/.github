# Run: intake

One issue was just opened. Decide what station it belongs to, whether it is
ready, and what single thing is missing if it is not.

## Do

1. Read the issue: `gh issue view $ISSUE --repo $REPO --comments`.
2. Read `README.md` in the checked-out repo for the current station definitions.
3. Check for a duplicate: `gh issue list --repo $REPO --state all --search "<the issue's key nouns>"`. A duplicate is the same *work*, not the same topic. If you find one, propose a comment naming it by number and stop there — do not also relabel.
4. Check `decisions/` for an ADR that already settled the question. If one has, say which and what it decided.
5. Apply the four-part definition of ready from your charter. State which parts pass.
6. Set the station label, and exactly one of `ready` or `needs-detail`.

## Output

- One `comment`: the station you chose and why, the ready verdict part by part, and — if not ready — the single most valuable missing piece with an example of what would satisfy it. Not a list of six things. One.
- `label` / `unlabel` for the station and readiness.
- `set-field` for Size if the work is clearly bounded; leave Priority to the weekly review, which sees the whole list.

## Not this run's job

- Estimating effort beyond a coarse Size.
- Ordering this issue against the rest of the backlog — you cannot see the list from here, and the weekly review can.
- Any comment on an issue other than `$ISSUE`.

## Done

The issue carries a station label, a readiness label, and one comment a human
could act on without opening anything else.
