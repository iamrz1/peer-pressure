# Moi

`moi` polishes your own change. It reviews it, applies the fixes, reviews what the fixes changed, and repeats until a review finds nothing new that matters. Nothing leaves the machine. `toi` is its counterpart for someone else's PR (see `babysit.md`).

`SKILL_DIR` is as in `SKILL.md`. You do the reviewing, the fixing and the committing. `moi-track.sh` keeps the record and decides when to stop.

## What it never does

- Push, force-push or amend. Every round is a new local commit.
- Post to GitHub, reply to a thread or submit a review. Threads from other reviewers are context only.
- Touch commits that were there before the run, or throw away work. If something fails, it stops and leaves the changes in the working tree.
- Review files that are not under git. Files mode is not supported. Use a branch.

## Start

1. Parse the request: `moi [<number>]`, with optional `--min-urgency insist|ask|author|optional` (default `ask`) and `--max-rounds N` (default 5). Keep the values as `MIN_URGENCY` and `MAX_ROUNDS`. A round applies only findings at that urgency or above, so a pass never chases nitpicks.
2. With a number, the PR must be the branch that is checked out. Compare `gh pr view <number> --json headRefName --jq .headRefName` with `git branch --show-current`. If they differ, tell the user to run `gh pr checkout <number>` and stop. Without a number, the target is the current branch against its base, as in Step 2 of `SKILL.md`.
3. The working tree must be clean: `git status --porcelain` prints nothing. Each round is committed with `git add -A`, so unrelated changes would end up in it. If the tree is dirty, say so and stop.
4. Set `MOI_DIR="$REPO_ROOT/.peer-pressure/moi-<label>"`, where `<label>` is `pr-<number>` or the branch name with `/` replaced by `-`. Run `"$SKILL_DIR/scripts/moi-track.sh" "$MOI_DIR" init "$(git rev-parse HEAD)"`. If a state already existed, tell the user you are resuming and from which round.
5. Ask once:

   > Polish this change? I review it, apply the fixes at <MIN_URGENCY> urgency and above, run the repo's checks, and commit each round locally, up to <MAX_ROUNDS> reviews. I never push, post or submit anything. (yes/no)

   Do nothing more until the user says yes.

## A round

Repeat. `<n>` is one more than the `rounds` value of the state.

1. `SESSION_DIR="$MOI_DIR/round-<n>"`. Prepare the input:
   - Round 1: the whole change, as in Step 2 of `SKILL.md` (a PR with `pr-context.sh`, a branch with `find-base.sh`).
   - Later rounds: only what the last round's fixes changed. Run `git diff "$(moi-track.sh "$MOI_DIR" get lastSha)" HEAD > "$SESSION_DIR/input.txt"`. If it is empty, nothing was fixed: stop as `nothing-changed`.
2. Review with Steps 3 to 8 of `SKILL.md`, with these differences:
   - From round 2, set `PRIOR_PREAMBLE` to the prompt that points at `$MOI_DIR/prior-findings.md`, and add: "This is the change made to fix earlier findings. Review only this change. Look for problems the fixes introduced and for fixes that are incomplete."
   - In Step 8, run `build-report.sh "$SESSION_DIR" --min-urgency "$MIN_URGENCY"`. Keep the held back count.
3. Record it: `"$SKILL_DIR/scripts/moi-track.sh" "$MOI_DIR" round "$SESSION_DIR/report.json" --max "$MAX_ROUNDS"`. Read `STOP`:
   - `converged`: no findings. Go to **Finish**.
   - `repeated`: a finding that an earlier round fixed has come back. The loop is not converging. Go to **Finish** and show which.
   - `max-rounds`: the last allowed review still has findings. Do not apply them. Go to **Finish**.
   - empty: apply them.
4. Apply with Step 11 of `SKILL.md`, items 2 to 6. Skip item 1, since you are on the branch. If the applier cannot apply a finding, note it. Do not retry it.
5. Check the result. Find the repo's own test and lint commands (the agent instructions, a `Makefile` or task runner, the package manifest, the CI config) and run the quick ones. If there are none, say so once and go on. If a check fails, try once to fix that failure. If it still fails, stop: leave the changes uncommitted in the working tree, say what failed, and go to **Finish**.
6. Commit: `git add -A`, then `git commit -m "fix: address review findings (round <n>)"`. Then run `"$SKILL_DIR/scripts/moi-track.sh" "$MOI_DIR" commit "$(git rev-parse HEAD)"`.
7. Say one line: the round, how many findings, how many applied, how many held back, the checks, the short commit sha.

## Finish

Say why it stopped (`converged`, `repeated`, `max-rounds`, `nothing-changed`, or a failed check) and give:

- the rounds and the commits: `git log --oneline <baseSha>..HEAD`, with `baseSha` from the state
- the findings that were not applied, and any left at `max-rounds` or `repeated`
- how many findings were held back below `MIN_URGENCY` in total

Then say nothing was pushed and give the user the choices: push the commits as they are, or `git reset --soft <baseSha>` to fold all rounds into one commit, or `git reset --hard <baseSha>` to drop them all. Do not run any of these.

## Resume

Running `moi` again continues from `state.json`. Check that the tree is clean and that `lastSha` is still in the branch history. Ask the question in Start step 5 again.
