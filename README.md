# peer-pressure

A code review skill where reviewers keep each other honest.

Seven independent reviewers look at your change: correctness, security, architecture, docs, compatibility, performance, and maintainability. Then validators try to disprove every finding against the real code. Only what survives reaches you.

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

| Flag | Effect |
|---|---|
| `-dir <path>` | Install into this skills directory instead of the defaults. Repeat for several. |
| `-dry-run` | Show what would change. |
| `-uninstall` | Remove the skill. |
| `-force` | Replace or remove a directory that peer-pressure did not install. |
| `-version` | Print the installer version. |

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
```

Elsewhere, ask in plain words: "Use the peer-pressure skill to review PR 123."

PR mode needs the [GitHub CLI](https://cli.github.com/) (`gh`, logged in) and `jq`. Branch and files modes need only `git`.

## How it works

```
input -> route -> 7 reviewers -> 7 validators -> synthesis -> summary -> you decide
                                                                           |-> apply fixes
                                                                           |-> pending PR review
```

1. **Route.** A script weighs the diff. Generated files and import-only changes count as nothing, tests as half, config as a quarter. Small changes get one quick reviewer. Big or high-stakes changes (auth, migrations, concurrency, public contracts) get the full pipeline.
2. **Review.** Each reviewer has one perspective and works alone.
3. **Validate.** Each validator reads every review and tries to disprove each claim. Wrong severity, wrong facts and already-handled cases get dropped.
4. **Synthesize.** One document with ranked, deduplicated findings.
5. **Summarize.** What the change does, how well, and an issue table. In PR mode the File column links to the exact line.
6. **You decide.** Apply fixes locally, post a pending review, both, or nothing.

If your agent can start subagents (Claude Code can), reviewers and validators run in parallel with separate contexts. Otherwise they run one after another in one context. That works but is slower, and the reviewers can influence each other, so quality drops a little.

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
  references/perspectives/    one prompt per reviewer
  references/pipeline/        validator, synthesizer, summary, planner, applier, formatter
  scripts/                    route-diff.sh, pr-context.sh, post-pending-review.sh
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
