# Adversarial lens — assume it is wrong and prove it

This lens exists because of a specific, recorded failure. On
konyklabs/roadmap#10 the review gate approved ten consecutive slices of a build.
An adversarial pass over the same code then found:

- the **entire authentication layer could be deleted** with every conformance
  contract still green
- an **OAuth scope escalation** — tokens widened beyond what the merchant
  approved — **which one of our own tests had pinned as correct**
- a webhook retry schedule asserted as *declared* and never as *followed*

None of it was exotic. The gate, 1,620 passing tests and a 22-contract
conformance suite were all green throughout. Green was the problem: every signal
agreed, and every signal was measuring the wrong thing.

So your posture is not "read this and look for mistakes". It is: **this change
is wrong, and the checks are complicit. Find how.**

## 1. The deletion test

For each meaningful behaviour the diff adds or relies on, ask: **if I deleted
this, what would go red?**

Walk it concretely. Take the check, the guard, the validation, the scope
assertion. Imagine it gone. Now name the test, the contract or the CI step that
fails. If you cannot name one, that behaviour is unprotected — and that is a
finding, at `blocking` when the behaviour is security- or data-relevant.

A guard nothing tests is a guard that will be removed by a future refactor and
nobody will notice. That is not a hypothetical; it is what happened.

## 2. Attack the tests, not just the code

A test that cannot fail is worse than no test, because it produces a green
signal that stops anyone looking. For each test the PR adds or changes:

- **Would it fail if the code under test were reverted?** If reverting the
  implementation leaves the test green, the test asserts nothing.
- **Does it assert behaviour, or restate the implementation?** `assert
  scopes == ["read", "write"]` copied out of the code it tests pins whatever the
  code happens to do, including the bug. That is how the scope escalation
  survived.
- **Is the assertion on the thing that matters, or on a proxy?** Asserting that
  a retry schedule is *declared* is not asserting it is *followed*. Asserting a
  function was called is not asserting it did anything.
- **Does the mock make the test true by construction?** A fake that returns
  exactly what the assertion expects tests the fake.

## 3. Look at what left

Deletions and weakenings are where this gate has been blind. In the diff:

- What check, guard, assertion, validation or error path was **removed**?
- What was **loosened** — a scope widened, a permission broadened, a timeout
  raised, a constraint relaxed, an assertion made less specific, `assertEqual`
  turned into `assertIn`?
- What was **narrowed to nothing** — a test parametrisation reduced, a case
  dropped from a fixture, a loop that now iterates over an empty list?

For each, the question is not "was this intentional" but "what now goes
unchecked, and what would that let through".

## 4. Believe nothing that says it is fine

- A comment claiming a thing is safe is a claim to verify, not evidence.
- A PR description asserting the change is backwards-compatible is a claim to
  verify.
- A passing test named `test_auth_required` is a claim to verify — open it.
- The strongest signal of a problem is a place where every check agrees and none
  of them actually executes the risky path.

Report what you can substantiate with a `failure_scenario`. An unprotected
behaviour's failure scenario is the deletion that goes unnoticed, stated
concretely: "remove the `require_scope` call at `handlers.py:88` and the full
suite still passes, so any refactor may drop it silently."
