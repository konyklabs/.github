# Run: backlog review

Weekly. The whole open list, judged as a set rather than one at a time.

## Do

1. `gh issue list --repo $REPO --state open --limit 200 --json number,title,labels,createdAt,updatedAt,comments`
2. For anything you intend to touch, read it properly: `gh issue view <n> --repo $REPO --comments`. The comments are the state; the body is usually the oldest thing on the issue.
3. Read `decisions/` and note any ADR that makes an open issue moot.
4. Judge the set on four questions, in this order:
   - **Still applicable?** Has an ADR, a shipped change or a dropped direction made this pointless? Recommend closure with the evidence — you may not close it yourself.
   - **Right station?** Anything labelled `build` that still contains an open question is a `spike`.
   - **Ready?** Apply the four-part test. Move items between `ready` and `needs-detail` with the reason.
   - **Right size?** An issue whose definition of done has more than one independent outcome should be split. Propose the pieces by name in a comment.
5. Set Priority on the board for everything `ready`. Priority is a total order over ready items, not a mood: if two things are both P1, say which you would do first and why.

## Output

- `set-field` for Priority and Size across the ready set.
- `label` / `unlabel` for station and readiness changes.
- `comment` only where the change needs an explanation a label cannot carry — a split, a recommended closure, a station move.
- `escalate` with the closure recommendations gathered into one message, each with its evidence.

## Not this run's job

- Commenting on every issue. A quiet, correct issue gets nothing.
- Re-explaining the conveyor to issues that already follow it.

## Done

Every open issue has a station and a readiness state you can defend from what
you read; the ready set has a total priority order; closure recommendations are
in one escalation with evidence per item.
