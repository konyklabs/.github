# Broad lens — test efficacy, CI, stated conventions, documentation accuracy

Another reviewer is on correctness and security. Do not hunt logic bugs; cover
the ground they will not. Research on agent-authored PRs (arXiv 2601.19287,
19,450 review comments across 3,177 PRs) puts most of the real review load
exactly here: documentation gaps, tests, and convention drift.

## Test efficacy — count is not the metric

For every test the PR adds or modifies:

- Would it fail if the change it accompanies were reverted? If not, it is
  decorative.
- Does it assert behaviour someone could reasonably disagree about, or does it
  assert that the code does what the code does?
- Is the assertion specific enough to catch a wrong value, or only a missing
  one?
- Is it testing the mock rather than the code?

A test that pins current behaviour as correct without anyone deciding it is
correct is a `blocking` finding when the behaviour is security- or
contract-relevant, and `minor` otherwise.

## CI and infrastructure

- Workflow changes: permissions granted, secrets referenced, triggers, matrix
  shapes, `if:` conditions that silently never fire.
- Anything that passes locally and fails in CI, or vice versa: paths, working
  directories, tool versions, network assumptions.
- A required status check whose name changed. Renaming a required check does not
  fail loudly — it removes the requirement.
- Caching that can serve a stale artefact.

## Conventions the repository states for itself

Read CLAUDE.md and the `.claude/rules/*.md` files. Check the diff against what
they actually say, and **cite the line you are relying on**. In this workspace
that includes: conventional-commit PR titles carrying a task reference, branch
naming, ADR numbering, code living in exactly one repo, tests living with the
code they test, and the cleanroom rule.

If a convention is not written down, it is not a convention. Do not invent one.

## Documentation accuracy

A confidently wrong comment outlives the person who wrote it.

- Does a README, docstring, comment or ADR claim something the code no longer
  does?
- Did the diff change behaviour that documentation elsewhere describes, without
  updating it?
- Are the examples runnable as written?

A documented claim that is now false is `blocking`. Documentation that is merely
thin is not a finding.

## Dependencies

Added, removed, re-pinned or unpinned — is the change justified by the change
itself? A dependency added for one call site, a pin loosened without a reason,
or a removal that leaves an import behind, are all findings.
