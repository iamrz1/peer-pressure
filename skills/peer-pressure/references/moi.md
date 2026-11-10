# Moi

`moi` takes your own change to approval. It reviews and fixes the change in rounds, pushes it, fixes CI failures, marks a draft PR ready, then waits for reviewers and answers them. It is done when the PR has the approvals the repo requires and is ready to merge, or when the PR is closed or merged. `toi` is its counterpart for someone else's PR (see `babysit.md`).

The user calling `moi` is the permission for everything in this file. Do not ask before you start, before you push, or before you reply.

Run every `gh` command, and every script that calls `gh`, OUTSIDE the sandbox from the first call (in Claude Code: `dangerouslyDisableSandbox: true` on the Bash call). The user has explicitly allowed this, so do not try inside the sandbox first and do not ask. See the Rules in `SKILL.md`.

`SKILL_DIR` is as in `SKILL.md`. You do the reviewing, the fixing, the committing and the writing. `moi-track.sh` keeps the record of the rounds and decides when a local loop stops. `babysit-poll.sh`, `babysit-wait.sh` and `babysit-post.sh` do the checking, the waiting and the replying.

## It NEVER waits on the user

THIS FILE OVERRIDES `SKILL.md`. Every instruction there to ask the user, to show a draft, to show the review first, or to wait for an OK or a yes before posting, applying, pushing or choosing (Steps 2, 4, 10, 11 and 12 and the Rules) DOES NOT APPLY to `moi`. Calling it IS the OK. NEVER ask and NEVER wait. Do not carry the question over from the ordinary review.

The user runs this for end-to-end automation and does not want to supervise it. Make every decision yourself and keep going. Never ask a question and never pause for an answer, not at the start, not between phases. When something needs the user (a thread you could not settle, a request outside this PR, CI you could not fix), say so in the phase summary and in a notification, leave that item alone, and carry on with the rest. A stop is a report, not a question: the run ends only when it is done, when the PR is merged or closed, when the user says stop, or when it cannot go on (a check that still fails after one fix, a rebase conflict, a local loop that does not converge).

## What it never does

- Force-push or amend, or rewrite a commit that is already pushed.
- Merge the PR, or submit a review.
- Resolve a thread that someone else started. That is the reviewer's call.
- Push to any branch except the PR's own, or touch commits that were there before the run.
- Touch the user's checkout or working tree when there is a PR. It works in its own temporary clone, so the user's branch and uncommitted changes do not matter.
- Throw work away. If something fails it stops and keeps the clone with the changes in it. It deletes the clone only when that clone is clean and everything in it is pushed.
- Mark the PR ready, or say it is done, while the local loop has findings it could not clear.
- Work on files that are not under git. Files mode is not supported. Use a branch.
- Do anything on a PR that is closed or merged. When the PR is closed, for whatever reason, the run ends with no further action: no push, no reply, no CI rerun, no `gh pr ready`. Before every push, every reply and every `gh pr ready`, check `gh pr view <number> --json state --jq .state`. If it is not `OPEN`, go to **Finish**.

## Start

1. Parse the request: `moi [<number>]` with optional `--min-urgency insist|ask|author|optional` (default `ask`), `--max-rounds N` (default 5), `--interval SECONDS` (default 60) and `--pending-replies`. Keep the values as `MIN_URGENCY`, `MAX_ROUNDS`, `INTERVAL` and `PENDING_REPLIES`. A round applies only findings at that urgency or above, so it never chases nitpicks. Replies to reviewers are posted at once, without asking. With `--pending-replies` they go into the user's pending review, and the user submits it.
2. Find the PR. With a number, use it. Without one, use the PR of the current branch (`gh pr view --json number --jq .number`). If there is none, the target is the current branch against its base, and `moi` runs only the **Local loop**, in place, in the user's checkout. Then the working tree must be clean (`git status --porcelain` prints nothing), because each round is committed with `git add -A` and unrelated changes would end up in it. If it is dirty, say so and stop. Say that you did not push, and that the user should open a PR and run `moi` again to continue. In this case `WORKDIR` is `REPO_ROOT` and there is no clone to remove.
3. Set `MOI_DIR="$REPO_ROOT/.peer-pressure/moi-<label>"`, where `<label>` is `pr-<number>` or the branch name with `/` replaced by `-`. The state and the session files stay there, in the user's repo, so that a closed terminal does not lose them. With a PR run `"$SKILL_DIR/scripts/babysit-state.sh" "$MOI_DIR" init <number> <owner/repo>`. If a state already existed, tell the user you are resuming and from which round. Then poll once: `"$SKILL_DIR/scripts/babysit-poll.sh" <number> "$MOI_DIR" --as author`. If `ACTION` is `done`, the PR is already closed or merged: go to **Finish** now, before you make a clone.
4. With a PR, make the working clone. If `"$SKILL_DIR/scripts/workdir.sh" path "$MOI_DIR"` prints a directory, reuse it. Otherwise run `"$SKILL_DIR/scripts/workdir.sh" create <number> <owner/repo> "$MOI_DIR"`. Keep `WORKDIR`. It is a temporary clone of the repository, on the PR's branch with its upstream set. Then run `"$SKILL_DIR/scripts/moi-track.sh" "$MOI_DIR" init "$(git -C "$WORKDIR" rev-parse HEAD)" <owner/repo>`. Without a PR run the same `moi-track.sh` line with `git rev-parse HEAD` from the checkout.

   From here, run every `git` and `gh` command and every script from `WORKDIR`, so that `gh` resolves the PR's repo. Wherever Steps 2 to 8 and 11 of `SKILL.md` give the repository to read, give `WORKDIR`. Tell the applier to edit files only under `WORKDIR`. Run the repo's checks there.
5. Say one line and go on: "Taking PR #<number> to approval in a temporary clone, so your checkout is not touched. I review and fix in rounds, push to the PR's branch, fix CI, mark it ready if it is a draft, and answer reviewers. I never merge, force-push, amend, submit a review or resolve anyone else's thread. Tell me to stop at any time." Do not wait for an answer. Do not write to `~/memory/`.

If the user has a writing-style skill, load it before you draft any reply.

## Local loop

Repeat rounds until a round tells you to stop. `<n>` is one more than the `total` value of the state, so every round of the run has its own directory.

1. `SESSION_DIR="$MOI_DIR/round-<n>"`. Prepare the input:
   - The first round of a run (`total` is 0): the whole change, as in Step 2 of `SKILL.md` (a PR with `pr-context.sh`, a branch with `find-base.sh`).
   - Later rounds, and the first round of a later cycle: only what the last commits changed. Run `git diff "$(moi-track.sh "$MOI_DIR" get lastSha)" HEAD > "$SESSION_DIR/input.txt"`. If it is empty, stop as `nothing-changed`.
2. Review with Steps 3 to 8 of `SKILL.md`, with these differences:
   - When `prior-findings.md` exists in `$MOI_DIR`, set `PRIOR_PREAMBLE` to the prompt that points at it, and add: "This is the change made to fix earlier findings or reviewer comments. Review only this change. Look for problems the changes introduced and for fixes that are incomplete."
   - In Step 8, run `build-report.sh "$SESSION_DIR" --min-urgency "$MIN_URGENCY"`. Keep the held back count.
3. Record it: `"$SKILL_DIR/scripts/moi-track.sh" "$MOI_DIR" round "$SESSION_DIR/report.json" --max "$MAX_ROUNDS"`. Read `STOP`:
   - `converged`: no findings. The loop is done.
   - `repeated`: a finding that an earlier round fixed has come back. The loop is not converging. Stop and show which.
   - `max-rounds`: the last allowed review still has findings. Do not apply them. Stop.
   - empty: apply them.
4. Apply with Step 11 of `SKILL.md`, items 2 to 6. Skip item 1, since you are on the branch. If the applier cannot apply a finding, note it. Do not retry it.
5. Check the result. Find the repo's own test and lint commands (the agent instructions, a `Makefile` or task runner, the package manifest, the CI config) and run the quick ones. If there are none, say so once and go on. If a check fails, try once to fix that failure. If it still fails, stop: leave the changes uncommitted in the working tree and tell the user what failed. Do not push.
6. Commit: `git add -A`, then `git commit -m "fix: address review findings (round <n>)"`. Then run `"$SKILL_DIR/scripts/moi-track.sh" "$MOI_DIR" commit "$(git rev-parse HEAD)"`.
7. Say one line: the round, how many findings, how many applied, how many held back, the checks, the short commit sha.

The loop ends as `converged`, `repeated`, `max-rounds`, `nothing-changed` or a failed check. Without a PR, say why it stopped and show `git log --oneline <baseSha>..HEAD`. Do not push. Stop.

## Push

With a PR, and when the loop did not fail a check: if there are commits that are not on the remote, run `git push` (`git push -u origin <branch>` when the branch has no upstream). If the push is rejected because the remote has new commits, run `git pull --rebase`, run the checks again and push again. If the rebase conflicts, stop and tell the user. Never force. If the loop stopped as `repeated` or `max-rounds`, push what was fixed, say which findings remain, and stop after this phase. Do not mark the PR ready.

## CI

Poll: `"$SKILL_DIR/scripts/babysit-poll.sh" <number> "$MOI_DIR" --as author`. Read `CI`.

- `pending`: wait with `babysit-wait.sh <number> "$MOI_DIR" --interval 30 --max 300 --as author` and poll again.
- `passing` or `none`: go on to **Ready**.
- `failing` (`ACTION=fix-ci`): find the failed jobs with `gh pr checks <number>`, and read each failed log with `gh run view <run-id> --log-failed`. Decide from the log:
  - The change caused it: fix it, run the checks, commit `fix: <what>`, push, and poll again.
  - It looks like a flaky test or infrastructure (a network error, a runner failure, a timeout in code the change does not touch): rerun it once with `gh run rerun <run-id> --failed`.
  - Count the attempts in the state (`babysit-state.sh "$MOI_DIR" set ciAttempts=<n>`). After three heads in a row that fail, or a failure you cannot explain, run `babysit-state.sh "$MOI_DIR" set ciHandledSha=<HEAD_SHA>`, tell the user, and go on to the **Wait** phase. The PR cannot become ready until the user deals with it.

## Ready

If `DRAFT` is `true` and the local loop was `converged`, run `gh pr ready <number>`. If the PR was not a draft, do nothing.

## Wait and answer reviewers

Repeat until `READY` is `true`, `ACTION` is `done` (the PR is closed or merged), or the user says stop. `READY` is true only when the repo's required approvals are in (`REVIEW_DECISION` is `APPROVED`, or the repo has no rule and one reviewer approved), nobody requests changes, CI is passing, the PR is not a draft, it has no conflict and no merge block, and no thread waits on the user. Until then keep waiting for reviewers and answering them.

1. Poll with `--as author`. Follow `ACTION`:
   - `done`: go to **Finish**.
   - `fix-ci`: do the failing branch of **CI**.
   - `respond`: do a **Respond pass**.
   - `idle`: wait.
2. If `READY` is `true`, go to **Finish**.
3. Wait: run `"$SKILL_DIR/scripts/babysit-wait.sh" <number> "$MOI_DIR" --interval <INTERVAL> --as author`, then go back to step 1. It returns when something changed, after 30 minutes, or after five failed polls (`WAIT=error`: tell the user and keep trying every few minutes).
   - If you can run a command in the background, run it there, so you are called again when it exits. Do not poll its output.
   - If you cannot, run it in the foreground with `--max` below the host's command time limit.
   - If you cannot wait at all, say the run is not continuous here and stop.

Notify the user with the host's notification tool when there is one, and always print the line in the terminal. Notify when: you pushed, a reviewer's comment needs the user's decision, CI could not be fixed, a pass failed, and the run ended.

### Respond pass

Read `waitingThreads` and `newComments` in `poll.json`. Decide for each thread from the code, not from how sure the reviewer sounds:

- **The comment is right.** Change the code. Reply in one short line that names the commit.
- **It is unclear.** Ask one question in a reply.
- **You disagree.** Reply once with the reason and the evidence, then hand it back with a question. After two of your replies in a thread and still no agreement, do not reply again. Note it in the phase summary and the notification, leave the thread open, and go on.
- **It is a question you can answer from the code.** Answer it in one or two sentences.
- **It asks for something large or outside this PR.** Do not act. Reply in one line that it is out of scope for this PR, note it in the phase summary, and go on.

Top-level comments and review summaries from others: read them, and act on a request in them the same way. Do not resolve any thread.

If you changed code: run the **Local loop** on that change (first `moi-track.sh "$MOI_DIR" cycle`, so the round count starts again and the findings already seen are kept), then push, as in **Push**. Reply only after the push, so that the commit you name is on the remote.

Write `<SESSION_DIR>/actions.json` with the replies as `babysit-post.sh` describes, with `SESSION_DIR="$MOI_DIR/respond-<k>"`, and post it:

```bash
"$SKILL_DIR/scripts/babysit-post.sh" <number> "$SESSION_DIR/actions.json"
```

Add `--pending` when `PENDING_REPLIES` is set. Replies are short and plain, in the user's voice. Do not thank, apologise or summarize. If it exits 1, show `FAILED` and the error.

Record the pass: `babysit-state.sh "$MOI_DIR" set lastSeenAt=<POLLED_AT>`, where `POLLED_AT` is from the poll that started the pass. Say one line: how many threads were answered, whether code changed, the pushed commit.

## Finish

First, whatever the reason, run `"$SKILL_DIR/scripts/workdir.sh" remove "$MOI_DIR"` when there is a clone. It deletes the clone only when that loses nothing. If it prints `KEPT`, tell the user the directory and the reason: after a failed check the changes are there, and unpushed commits too. Then:

- `READY` is `true`: tell the user "PR #<number> has the approvals it needs and is ready to merge. Merge it yourself." Add the rounds, the CI fixes and the threads answered. Show the commits with `git log --oneline <baseSha>..HEAD`. Stop. Do not merge.
- `END_REASON` is `merged` or `closed`: say which in one line, and stop. Take no other action.
- The local loop stopped as `repeated`, `max-rounds`, `nothing-changed` or a failed check: say why, list the findings that remain, and stop.

## Resume

Running `moi` again continues from `state.json`. The clone from the earlier run is reused when it is still there. If it is gone, make a new one, and set `lastSha` to its head with `moi-track.sh "$MOI_DIR" commit "$(git -C "$WORKDIR" rev-parse HEAD)"`. Rounds that were never pushed are lost with the clone, so say so. 
