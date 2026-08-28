# arch — the model of konyklabs

What exists, how it connects, and a check that fails when this stops being true.
Driven by [konyklabs/roadmap#29](https://github.com/konyklabs/roadmap/issues/29);
the tool choice is [D-005](https://github.com/konyklabs/roadmap/blob/main/decisions/D-005-architecture-as-code.md).

**Read it:** [generated/VIEWS.md](generated/VIEWS.md) — eight views, rendered, no
tooling required.
**Explore it:** `npm --prefix arch install && npm --prefix arch run dev` — an
interactive site with click-through nesting and every element's description.
**Change it:** edit `model/*.c4`, then `npm --prefix arch run gen` and
`./arch/drift.sh`. Both run in CI on every PR that touches this or its sources.

## The views, and the question each answers

| View | Question |
|---|---|
| `index` | What is there at all? |
| `repos` | What is each repository for, and who calls the shared workflows? |
| `gate` | How is a change admitted? |
| `clock` | What runs while nobody is watching? |
| `agents` | Every agent in the org, in one place. |
| `trust` | Where a model is trusted, and where it is not. |
| `changeLifecycle` | How one idea becomes a release. |
| `roleRun` | What happens at 06:23 UTC. |

## The one thing the model is for

`trust` is the view that earns the rest. Two tags cut across every element kind:

- `#model-in-it` — a language model runs here, so its output is a proposal
- `#no-model` — arithmetic and scripts, which is what every verdict runs on

Every path from a `#model-in-it` element to a durable record passes through a
`#no-model` element first. The review gate's lenses hold no tool that can post
and a script computes the verdict; the role jobs' `propose` holds read scopes
only and a script with no model applies. That is one invariant, implemented
twice, and it is very hard to see from the files. It is one view here.

A future diagram showing red reach a record without a green hop is showing a
defect, not a drawing mistake.

## Why LikeC4 and not the alternatives

Recorded properly in D-005. In short:

- **Structurizr DSL** — the reference C4 implementation, and stricter. Rejected
  on the model, not the rendering: C4's container/component split describes a
  deployed system, and this org's units are a repository, a workflow, a charter
  and a scheduled job. LikeC4 takes custom element kinds and arbitrary nesting,
  so the vocabulary is ours.
- **Backstage** — the right answer to "a catalog of what we run", and a platform
  you operate rather than a tool you open. A hosted app with a database, for one
  person and nine repositories, against a $25 budget alarm.
- **Mermaid or D2 alone** — drawings, not a model. Nothing to query, nothing to
  check, and eight views to hand-maintain. We generate Mermaid *from* the model
  instead, which is the half of it that was worth having.

## What drift.sh actually checks

It reads the repositories and the model's JSON export and compares them both
ways — something real that the model omits is drift, and so is something the
model claims that does not exist.

1. Every repository in the org, against every `repo` element.
2. Every workflow here carrying `workflow_call:`, against every `reusable`.
3. Every lens id in `review/matrix.json`, against the gate's lens agents.
4. Every charter in `roles/agents/`, against the role agents.
5. Every job in `roles/registry.json` — its role must exist and its charter edge
   must name that job, so a job cannot be added without an owner in the model.
6. Every `uses: konyklabs/.github/...` in every repository, against the `calls`
   relationships.

Check 6 needs cross-repo reads. With `ROLE_READ_TOKEN` it covers the org; without
it, it names the repositories it could not read and prints `SKIP`. It does not
report a smaller org as a healthy one — that is the failure mode `roles/bin/fetch.sh`
was rewritten to avoid, and it applies here identically.

Exit `0` agrees, `1` drift, `2` could not run.
