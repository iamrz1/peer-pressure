# peer-pressure

A code review skill where reviewers keep each other honest.

Three reviewers look at your change through seven perspectives: correctness, security, architecture, docs, compatibility, performance, and maintainability. Every finding must carry evidence. Then an independent verifier tries to disprove each one against the real code. Only what survives reaches you.

It reviews a GitHub PR, your current branch, or specific files. You always see the review first. It applies fixes or posts a **pending** PR review only when you say so, and it never submits a review.

## Install

One command fetches the skill and puts it in place. It needs [Go](https://go.dev/dl/) 1.22 or newer.

```sh
go run github.com/iamrz1/peer-pressure/cmd/install@latest
```

It installs to:

- `~/.agents/skills/peer-pressure`, which Codex, OpenCode, Copilot, Cursor and Amp read.
- `~/.claude/skills/peer-pressure`, only when `~/.claude` exists, because Claude Code reads only that path.

Run the same command again to update. It replaces the copy it installed earlier and prints the old and new version.

To see what is installed and whether a newer release exists, add `-status`:

```sh
go run github.com/iamrz1/peer-pressure/cmd/install@latest -status
```

| Flag | Effect |
|---|---|
| `-dir <path>` | Install into this skills directory instead of the defaults. Repeat for several. |
| `-dry-run` | Show what would change. |
| `-uninstall` | Remove the skill. |
| `-force` | Replace or remove a directory that peer-pressure did not install. |
| `-status` | Show the installed version and hash for each target, and the latest release. Changes nothing. |

Safety rules of the installer:

- It only replaces a directory that holds its marker file `.peer-pressure-install.json`. A different skill with the same name is left alone and reported.
- It never writes through a symlink.
- It stages the new copy outside the skills directory, so an agent never sees a half-written skill.
- Local edits to an installed copy are overwritten on update. Copy the folder under another name first if you want to change it.

Pin a version with `@v0.1.0` instead of `@latest`. If a brand new release is not found yet, add `GOPROXY=direct`.

## Use

In an agent with slash commands:

```
/peer-pressure 123             review PR #123 in the current repo
/peer-pressure                 review the current branch against its base
/peer-pressure src/a.go b.md   review specific files
/peer-pressure --full 123      force the full pipeline
/peer-pressure --quick 123     force the quick single-pass review
/peer-pressure --width 120 123  table width in characters (default 140)
/peer-pressure --base feat/a    review against this ref (branch mode, for a stacked branch)
/peer-pressure --stack 123      review the whole stack that PR 123 is in (--single: only that PR)
```

If PR 123 is part of a stack of PRs, you are asked whether to review only that PR or the whole stack. A whole-stack review runs the pipeline once on the combined diff, so problems between PRs are found. Each finding is then given to the PR that added the line, marked `#<number>` in the table, and posted as a pending review on that PR only.

Elsewhere, ask in plain words: "Use the peer-pressure skill to review PR 123."

PR mode needs the [GitHub CLI](https://cli.github.com/) (`gh`, logged in) and `jq`. Branch and files modes need only `git`.

## How it works

```
input -> route -> split -> 3 reviewers -> cluster -> verifier -> score -> report -> summary -> you decide
                                                                                       |-> apply fixes
                                                                                       |-> pending PR review
```

1. **Route.** A script weighs the diff. Generated files and import-only changes count as nothing, tests as half, config as a quarter. Small changes get one quick reviewer. Big or high-stakes changes (auth, migrations, concurrency, public contracts) get the full pipeline.
2. **Split.** A script cuts a large diff at file boundaries into chunks of about 50k tokens, so no agent needs a large context window. Most changes are one chunk.
3. **Review.** Three reviewers read each chunk once. `behavior` covers correctness, security and performance, `contracts` covers compatibility and docs, and `structure` covers architecture and maintainability. Every finding fits one category of the review bar (`references/bar.md`): unsound, regression, intent, convention (including duplicated code) or docs. It names a lens, carries evidence (the line, the existing code or the documentation) and has its own 0 to 3 score. Taste is left out.
4. **Cluster.** A script drops findings that lack a category or evidence, then groups findings about the same place.
5. **Verify.** One verifier, who did not write the findings, tries to disprove each cluster against the real code and looks things up when the code does not settle a claim. It merges duplicates and drops nits. A claim it cannot settle stays only if it can state a high-confidence argument. It also decides how hard to push each survivor: `Insist`, `Ask`, `Up to author` or `Optional`. Severity says how bad the problem is. Urgency also weighs the size of the fix, how far the problem reaches, and whether the code is new in this change. A large review gets one verifier per 8 clusters.
6. **Score.** A script sums the lens scores and sets the label from the highest single score: 3 is critical, 2 is warning, anything lower is suggestion. A sum alone would let a style nit that every lens mentions outrank a data-loss bug that only one lens sees.
7. **Summarize.** Your agent writes what the change does and how well, from a short note the structure reviewer leaves. A script then draws the issue table (file, severity and score, urgency, review, fix) at a fixed width, so it stays aligned however many rows there are. The default width is 140 characters. A script cannot read your terminal size, so pass `--width N` to match it.
8. **You decide.** Apply fixes locally, post a pending review, both, or nothing.

A full review of one chunk uses four agents: three reviewers and one verifier. Merging, urgency for the quick path and the summary happen in your own session.

If your agent can start subagents (Claude Code can), the reviewers run in parallel with separate contexts. Otherwise everything runs one after another in one context. That works but is slower, and the verification is less independent, so quality drops a little.

On a PR that already has review threads, reviewers skip points that are already raised.

## Safety

- The review is shown before anything else happens.
- Posted reviews stay **pending**. You submit them in GitHub. The posting script refuses any payload that could submit a review.
- Comments on lines outside the diff go into the review body, because GitHub rejects the whole review otherwise.
- Review files live in `.peer-pressure/` in the repo and are excluded through `.git/info/exclude`. Your `.gitignore` is not touched.
- Do not review changes that contain personal data, health data or secrets with a tool you have not cleared for that. The review text is sent to your agent's model provider, and posted comments go to GitHub.

## Layout

```
skills/peer-pressure/
  SKILL.md                    the orchestrator
  references/perspectives/    one checklist per perspective
  references/bar.md           the review bar every reviewer and the verifier applies
  references/pipeline/        reviewer, verifier, urgency, quick-reviewer, summary, planner, applier, formatter
  scripts/                    route-diff.sh, split-diff.sh, cluster-findings.sh, apply-verdicts.sh, find-base.sh, find-stack.sh, stack-context.sh, assign-prs.sh, score-findings.sh, build-report.sh, render-table.sh, pr-context.sh, post-pending-review.sh
cmd/install/                  the installer
internal/install/             copy and replace logic
test/                         offline script tests with a stubbed gh
```

## Development

```sh
go vet ./... && go test ./...   # installer and skill structure checks
test/run.sh                     # script tests, needs jq
```

`go test` checks that `SKILL.md` has portable frontmatter, that every reference is linked, and that no private or stale content slipped in.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/). PRs are squash-merged, so the PR title must be conventional. A `feat:` or `fix:` title makes release-please open a release PR. Merging it tags `vX.Y.Z`, and `go run ...@latest` picks that tag up.

The repo setting "Allow GitHub Actions to create and approve pull requests" must be on, or release-please cannot open its PR.

## Not included

The upstream project also had an auto-fix loop (`--loop`) and a spec-review mode. They are left out to keep this small.

## Credits

Based on [`mechanai/deepreview`](https://github.com/mechanai/deepreview) by Mark Lee. The reviewer prompts and pipeline come from it. See [LICENSE](LICENSE).
