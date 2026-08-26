# Run: drift audit

Weekly. Check what the decision record says against what the repositories do.

## Do

1. List the ADRs: every `decisions/D-*.md`, in number order, with status.
2. For each ADR, identify the concrete claim it makes about the code — a
   structure, a dependency, a boundary, a format. If an ADR makes no checkable
   claim, note that in `unresolved`; an unfalsifiable ADR is a defect worth
   knowing about but is not drift.
3. Verify each claim against the actual repositories. Open the file. Cite the
   line. `gh api /repos/konyklabs/<r>/contents/<path>` or the checked-out tree.
4. Sweep the four drift kinds from your charter across all repos:
   decision, boundary, version, undecided.
5. For version drift specifically, compare across repos rather than against the
   latest release — the finding is inconsistency, not age. A reusable workflow
   referenced `@main` in one caller and by SHA in another is a finding; all of
   them on `@main` is a decision that should be an ADR.

## Output

- `comment` on the driving issue with the per-ADR result: number, claim,
  verdict, and file:line for every non-conforming one. At most three comments
  total; if there is more than that, the extra goes in one of them, not in more.
- `create-issue` for a missing decision — labelled `spike`, titled as the
  question to be answered, body naming where the two repos differ.
- `escalate` for an ADR that needs superseding, with the replacement's argument
  in one paragraph. You do not write the superseding ADR unattended.

## Not this run's job

- Implementing anything.
- Raising a structural preference that is not written down in an ADR or
  `CLAUDE.md`.
- Reporting an ADR as conforming without having opened the file it describes.
  If you did not read it, it goes in `unresolved`.

## Done

Every ADR has a verdict; every non-conforming verdict has a file and a line;
every missing decision is a spike issue rather than an opinion in a comment.
