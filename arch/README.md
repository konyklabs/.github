# arch — the model of konyklabs

What exists, how it connects, and a check that fails when this stops being true.
Driven by [konyklabs/roadmap#29](https://github.com/konyklabs/roadmap/issues/29);
the tool choice is [D-005](https://github.com/konyklabs/roadmap/blob/main/decisions/D-005-architecture-as-code.md).

**Read it:** [generated/VIEWS.md](generated/VIEWS.md) — eight views, rendered, no
tooling required.
**Explore it:** `npm --prefix arch install && npm --prefix arch run dev` — an
interactive site with click-through nesting and every element's description.
**Change it:** `npm --prefix arch install` once, then edit `model/*.c4`, then
`npm --prefix arch run gen` and `./arch/drift.sh`. Both run in CI on every PR
that touches this or its sources. The renderer version in `package.json` is the
one both scripts use — they resolve the installed copy, or that exact version,
never `@latest`.

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
defect, not a drawing mistake — and check 7 below fails the build on one, because
a picture nobody opens is not an alarm.

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

It reads the repositories and the model's JSON export. Checks 1-4 and 6 are set
comparisons run in **both** directions — something real that the model omits is
drift, and so is something the model claims that does not exist. Checks 5 and 7
are different in shape and are described as what they are.

1. Every repository in the org, against every `repo` element.
2. Every workflow here carrying `workflow_call:`, against every `reusable`.
3. Every lens id in `review/matrix.json`, against every agent tagged `#lens`.
4. Every charter in `roles/agents/`, against every agent tagged `#charter`.
5. Every job in `roles/registry.json` — its role must exist and its charter edge
   must name that job, so a job cannot be added without an owner in the model.
6. Every `uses: konyklabs/.github/...` in every repository, against the `calls`
   relationships.
7. The invariant: no element tagged `#model-in-it` may be the source of an
   `applies` edge. This is the rule the `trust` view draws, enforced.

Checks 3 and 4 select on **tags**, not on how a title is spelled. That is not
tidiness: an earlier revision built check 4's model side by grepping the model's
agent titles for the real filenames, which made it a subset of reality by
construction, so a charter the model had invented could never be reported. The
model has to state what a thing is.

Checks 1 and 6 need cross-repo reads, and what they can prove depends on the
credential. `GITHUB_TOKEN` is scoped to one repository, so `gh repo list` under it
returns the org's **public** repositories and nothing else.

With `ROLE_READ_TOKEN` both checks cover the org and hold in both directions.
Without it, check 1 drops to one direction — everything visible must be modelled,
and a repository the token cannot see is neither confirmed nor denied — and check 6
names the repositories it could not read. Both print `SKIP` with the reason.

**CI does not supply that token, on purpose.** `arch-drift.yml` checks out the
pull request head and runs `drift.sh` from it, and `arch/**` is in its paths
filter, so a pull request that rewrites `drift.sh` is exactly the pull request
that runs it. Putting a cross-repo read PAT in that environment would hand it to
PR-authored code and invert the rule `role-job.yml` is built on — data in,
credential out. The roles pay for the safe version with a second checkout of the
default branch; this check is not worth that machinery, so it runs narrow in CI
and says so every time. `drift.sh` still reads the variable when something
trusted supplies it.

That distinction is not fussiness. The first CI run of this script treated the
public-only listing as the org and reported five private repositories as
nonexistent: a confident, wrong finding, which is worse than no finding. The same
mistake in the other direction — quietly reporting a narrowed check as a passing
one — is what `roles/bin/fetch.sh` was rewritten to avoid. Both are refused here.

Exit `0` agrees, `1` drift, `2` could not run.
