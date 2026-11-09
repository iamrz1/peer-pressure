# Review bar

A review steers the change in the right direction. It does not impose the reviewer's own taste. A finding belongs in the review only when the change:

1. `unsound`: is unsound or wasteful. A bug, a race, a leak, or a cost that matters on a real path.
2. `regression`: regresses something that worked, or breaks a caller.
3. `intent`: does not do what it is meant to do. Check the PR title, the description or the spec.
4. `convention`: breaks good practice or a convention the repo already follows. A new logging, assertion or error library, or a second way to do what the repo already does one way, is the usual case. So is code that is not DRY: a block of logic copied within the change, a type, enum or constant set that mirrors one the repo already has, or code that reimplements an existing helper. Name the existing code. Two similar lines are not a finding.
5. `docs`: has no documentation of what it does, or documentation that is wrong. A short, correct comment is enough. Do not ask for more.

Every finding carries one of these tags as its `bar` category. A reviewer who has evidence for a problem that fits none of them tags it `other`. The verifier decides.

The verifier and the quick reviewer leave out everything else, in particular:

- a different but equivalent way to write the same thing
- naming, wording and formatting taste
- refactors and "could be simpler" ideas that fix no defect
- concerns about future needs that nobody has today
- style that a linter or formatter already enforces
- tidiness of test code (helper design, names, fixtures), unless it can mask a real bug or leak into production code

## Evidence

Every finding needs a fact behind it. No guessing.

- Point to what proves it: the line that is wrong, the existing usage it breaks, the caller it breaks, or the documented behavior it contradicts. Write that evidence into the finding.
- Check before you claim. Read the surrounding code and the callers. When the claim depends on a library, tool, API or spec, look up its documentation (`--help`, a man page, the vendored source, or the web when you can) and name what you found.
- Reviewers: report every candidate you can back with evidence, even when you expect someone to dispute it or think it small. A later step decides. Do not hold a finding back because it may be a nit, rare, or unlikely to be fixed. Do hold back a claim you could not check.
- The verifier and a single-pass quick reviewer: confidence must be high. A claim you still cannot verify after looking it up is left out.

## Scores

Score each finding from 0 to 3 for the lenses that care. A real but small issue scores 1. Do not inflate.

| Lens | 1 (minor) | 2 (significant) | 3 (severe) |
|---|---|---|---|
| correctness | cosmetic or very unlikely edge case | wrong result in a realistic case | data loss, crash, or wrong result on the common path |
| security | hardening gap | exploitable with preconditions | exploitable by an outsider, or exposes secrets |
| architecture | small mismatch with local patterns | wrong layer or coupling that will spread | breaks an invariant or blocks future change |
| docs | stale or verbose wording | misleading claim | false claim that causes API misuse |
| compatibility | breaks internal callers only | breaks some consumers | breaks a public contract or persisted data |
| performance | minor waste | clear cost on a hot path | unbounded growth or failure under load |
| maintainability | naming or style | hard to change safely | hides bugs or makes edits unsafe |

## Rules

For every step:

- A convention finding must name the existing usage in the repo, with a file and line. A convention you cannot point to is taste.
- State the consequence in one sentence.

For the verifier and the quick reviewer only. Reviewers do not apply these:

- Final check: would a thoughtful maintainer ask the author to change this before merging? If not, leave it out.
- A short review of real issues beats a long one with nits.
