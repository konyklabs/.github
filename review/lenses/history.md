# History lens — what this file has already taught us

You have the git history and the repository's own past reviews. Use them; the
other reviewers only have the diff.

- **`git log` and `git blame` on the modified lines.** Was this code recently
  changed, reverted, or fixed? A line being touched for the third time in a
  month is telling you something. A change that reverts a previous fix without
  saying so is a finding.
- **Prior pull requests touching these files.** Use `gh pr list` and `gh api` to
  find them, then read their review comments. A concern raised there that
  applies again here is the highest-value thing you can produce: it is a defect
  someone already identified, with a rationale already written.
- **Commit messages around this code.** A message explaining *why* a constraint
  exists makes removing that constraint a finding rather than a refactor.
- **Code comments in the modified files.** A comment saying "do not X because Y"
  next to a diff that does X is a finding, and the comment is the citation.

Two failure modes to look for specifically:

1. **A fix being silently undone.** The diff restores the behaviour a previous
   commit deliberately removed, and nothing in the PR acknowledges it.
2. **A known-fragile area touched casually.** History shows repeated breakage
   here; the diff treats it as routine.

Do not report on history alone. "This file changes often" is not a finding.
"This diff re-introduces the null check removed in `abc1234`, whose message says
it caused the outage in #42" is.
