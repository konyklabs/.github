# roles

The org's governance roles. A role is not a personality — it is an artifact it
owns, a set of things it may propose, and a clock it runs on. Everything else is
decoration, and the evidence on persona prompting says decoration does not help.

## One file is the whole charter

`agents/<role>.md` is simultaneously the Claude Code subagent definition (YAML
frontmatter) and the charter (the body). There is no second copy to drift from.
The body always answers five questions in this order:

- **Owns** — the durable artifact this role is answerable for.
- **Reads** — where it gets its facts, as commands, not as prose.
- **Proposes** — the action types it may emit, and nothing outside them.
- **Never** — the things it must escalate instead of doing.
- **Done** — how a run is judged complete without asking anyone.

A role that owns no durable artifact, or that has no recurring job, does not get
a file here. That is the whole admission test.

## Three runtimes, same files

| Runtime | How it loads | Authority |
|---|---|---|
| Interactive session | plugin `roles@konyklabs` installs `agents/` | green band of `agentic-sdlc.md` — Oleg is in the loop |
| CI, event-driven | `role-job.yml` concatenates charter + run brief | propose only |
| Cron | the same workflow on a `schedule:` | propose only |

Unattended, a role **proposes and never disposes**. The agent job holds
`contents: read` and nothing else, so it is not trusted to refrain from posting
— it is structurally unable to. It emits JSON against `schemas/proposal.json`;
a second job with no model in it validates against the caps in `registry.json`
and applies. That is the review gate's invariant, reused: nothing a model wrote
reaches a durable surface unfiltered.

Every check runs before the first write, so a proposal that breaches any
boundary applies **nothing** — not the part that fit. Three of those boundaries
are worth naming because each closes a failure that is otherwise silent:

- **`surveyed`** — a proposal must say how many items it read and through which
  commands, and a run that read zero is refused. Without it, a token missing
  `issues: read` produces an empty proposal, which is exactly what a healthy
  backlog produces, and every surface downstream reads green forever.
- **`scope`** — a job triggered by `issues.opened` may act only on that issue.
  Its primary input is text a stranger wrote, and "not this run's job" in a
  brief is a prompt, not a boundary.
- **typed values** — `set-field` runs under a PAT that the job's `permissions:`
  block does not bound, so nothing model-authored is ever concatenated into a
  GraphQL document.

## The clock

`registry.json` is the only list of unattended jobs. Cadence, model, turn cap
and per-action caps all live there, so a role cannot vote itself more compute or
a wider blast radius — changing either is a reviewable diff.

Receipts are not a new datastore. The Actions run history *is* the receipt:
`bin/heartbeat.sh` reads `/repos/<repo>/actions/runs` and matches each run's
`display_title` against `role/<job-id>` — two segments, the registry id, e.g.
`role/dm-flow-sweep`.

**The caller sets that title, not this repo.** GitHub defaults `display_title`
to the triggering commit message, so a caller without a `run-name:` key leaves
the heartbeat with nothing to match and every job reads as missing. The caller
must map its triggers to registry ids:

```yaml
run-name: >-
  role/${{ github.event.schedule == '23 6 * * *' && 'dm-flow-sweep' || ... }}
```

The heartbeat reports that specific misconfiguration as one fault rather than as
one false alarm per job. A job that genuinely stops firing gets an issue opened
against it within its window (`konyklabs/roadmap#12`).

Both workflows take `stage: true`, which prints every write to the step summary
and makes none. That includes the heartbeat, which holds `issues: write` and
would otherwise open or close a live tracking issue on the first invocation
someone meant as a dry run.

## Adding a role

1. It must fail the admission test above before you write anything.
2. `agents/<role>.md` — charter, five sections, in that order.
3. `runs/<role>/<job>.md` — one brief per unattended job, each with its own
   definition of done and its own explicit list of what is *not* a finding.
4. An entry in `registry.json` with caps you can defend.
5. A caller entry in the consuming repo's `roles.yml`.
6. An ADR if the role changes who decides what. Adding a role that only reports
   is not a decision; adding one that closes issues is.

## Deferred roles, and what would admit them

- `qa` — when the conformance suite has an owner other than the review gate.
- `security` — when `proprietary-scan` produces findings a human triages rather
  than a binary pass.
- `release-manager` — when release-please stops being sufficient on its own.
