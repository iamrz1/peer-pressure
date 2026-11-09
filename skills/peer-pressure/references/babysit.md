# Babysit

`babysit <PR>` (also `toi <PR>`) reviews a PR over its whole life. It reviews each push as it arrives, follows up on the threads it raised, tells the user what happened, and stops when the PR is merged or closed. It is for reviewing someone else's PR. `moi` is the counterpart for your own change (see `moi.md`).

`SKILL_DIR` is as in `SKILL.md`. The scripts do the checking and the posting. You decide what to review and what to say.

## What it never does

- Merge, push or force-push, or change the PR's code. Babysit reviews only.
- Touch the user's checkout or working tree. It works in its own temporary clone.
- Submit a review. Everything it writes goes into the user's pending review. The user submits it.
- Reply or post anything when no one asked it to babysit this PR.
- Stop by itself before the PR is merged or closed. Only the user stops it, or closing the terminal.

Resolving a thread is the one action that takes effect at once, because GitHub has no pending state for it. Say so when you ask for permission.

## Start

1. Parse the request: `babysit <number>`, with optional `--interval SECONDS` (default 60) and `--min-urgency insist|ask|author|optional` (default `ask`). A babysit run posts only findings at that urgency or above, so there are no nitpicks. Keep the values as `INTERVAL` and `MIN_URGENCY`.
2. Check the repo as in Step 2 of `SKILL.md`. Set `BABYSIT_DIR="$REPO_ROOT/.peer-pressure/babysit-pr-<number>"` (it is already excluded from git) and run `"$SKILL_DIR/scripts/babysit-state.sh" "$BABYSIT_DIR" init <number> <owner/repo>`. If the state already existed, tell the user you are resuming and from which pass.

   The state and the session files stay in `BABYSIT_DIR`, in the user's repo, so that a closed terminal does not lose them. The code is read in a temporary clone: if `"$SKILL_DIR/scripts/workdir.sh" path "$BABYSIT_DIR"` prints a directory, reuse it. Otherwise run `"$SKILL_DIR/scripts/workdir.sh" create <number> <owner/repo> "$BABYSIT_DIR" --read-only`. Keep `WORKDIR`. It is the PR's head, checked out detached. The user's own checkout can be on any branch and in any state.
3. Run `"$SKILL_DIR/scripts/babysit-poll.sh" <number> "$BABYSIT_DIR"`. If `STATE` is not `OPEN`, say so and stop. If `VIEWER` equals `AUTHOR`, say that babysit reviews other people's PRs and stop.
4. If `~/memory/` exists, keep a short note in `~/memory/<task>.md`, where `<task>` is the ticket or branch name. Re-read the file before each write and append a timestamped line. Ask the user before creating a file that does not exist yet.
5. Ask once:

   > Babysit PR #<number> until it is merged or closed? On every push I review only what changed and add findings (<MIN_URGENCY> and above) and replies to your pending review. You submit that review, I never do. I resolve threads I raised once the fix is in, which takes effect at once. I never merge or push. Tell me to stop at any time. (yes/no)

   Do nothing more until the user says yes. That answer covers this PR for this run. Do not carry it to another PR.

## The loop

Repeat until `STATE` is `MERGED` or `CLOSED` or the user says stop.

1. Poll: `"$SKILL_DIR/scripts/babysit-poll.sh" <number> "$BABYSIT_DIR"`. Keep the output and `poll.json`. Follow `ACTION`:
   - `done`: go to **Finish**.
   - `review`: do a **Review pass**, then a **Thread pass**.
   - `respond`: do a **Thread pass**.
   - `idle`: go to step 3.
2. After the pass, if `READY_NOTICE` is `true`, tell the user: "PR #<number> looks ready to merge: CI passing, no open threads, the last push reviewed. Merge it yourself. I keep watching." Then run `babysit-state.sh "$BABYSIT_DIR" set readyNotifiedSha=<HEAD_SHA>`. This is not the end. A new push or a new thread keeps the loop going, and a later ready head is announced again.
3. Wait: run `"$SKILL_DIR/scripts/babysit-wait.sh" <number> "$BABYSIT_DIR" --interval <INTERVAL>` and go back to step 1 when it returns. It returns when something changed, after 30 minutes, or after five failed polls (`WAIT=error`: tell the user and keep trying every few minutes).
   - If you can run a command in the background, run it there, so that you are called again when it exits. Do not poll its output.
   - If you cannot, run it in the foreground with `--max` below the host's command time limit.
   - If you cannot wait at all, do one pass, tell the user the run is not continuous here, and stop.

Notify the user with the host's notification tool when there is one, and always print the line in the terminal. Notify when: a pass added something to the pending review, the PR is ready, a thread needs the user's decision, a pass failed, and the PR ended.

## Review pass

Review what changed since the last review, not the whole PR again. Run every `git` and `gh` command and every script from `WORKDIR`, so that `gh` resolves the PR's repo. Wherever Steps 3 to 8 of `SKILL.md` give the repository to read, give `WORKDIR`, not the user's checkout.

1. `SESSION_DIR="$BABYSIT_DIR/pass-<pass>"`, where `<pass>` is the `pass` value in the state plus one. Run `"$SKILL_DIR/scripts/workdir.sh" sync "$BABYSIT_DIR"` to bring the clone to the current head. Then, from `WORKDIR`, run `"$SKILL_DIR/scripts/babysit-delta.sh" <number> "$BABYSIT_DIR" "$SESSION_DIR"`. Keep `DELTA` and `FROM_SHA`.
   - `none`: nothing to review. Go to the **Thread pass**.
   - `full`: the first pass, or the branch was force-pushed. Review the whole PR and say which.
2. Follow Steps 3 to 8 of `SKILL.md` with `input.txt` as the change, with these differences:
   - `PRIOR_PREAMBLE` is always set, because your own threads exist. Do not report again what is already open or resolved.
   - For an incremental delta, add to the preamble: "This is the change since commit <FROM_SHA>. Review only this change. Code outside it is out of scope unless this change breaks it."
   - In Step 8, run `build-report.sh "$SESSION_DIR" --min-urgency "$MIN_URGENCY"`. Keep how many findings were held back.
3. If the report has findings, follow Step 12.1 of `SKILL.md` to write `<SESSION_DIR>/threads.json`, with the delta as the diff. Do not post yet. The **Thread pass** posts everything once.

If the pass fails, do not advance the state. The next poll tries again. After two failures on the same head, tell the user and keep watching for a new push.

## Thread pass

Look at the threads in `poll.json`: `ownThreads` (threads you or the user raised that are still open) and `newReplies`. Read only those, and the code at the head they point to.

For each own thread, decide from the code, not from what anyone says:

- **Fixed.** The problem is gone at the head. Reply in one short line that names the commit (`Fixed in <short sha>.`), and add the thread to `resolve`.
- **The author gave a reason.** Check the reason against the code. If they are right, reply in one line that you agree, and resolve. If they are wrong, reply once with the evidence and leave the thread open.
- **Still disagreeing after two of your replies.** Do not reply again. Tell the user the thread needs a decision.
- **A question you can answer from the code.** Answer it in one or two sentences. Otherwise tell the user.
- **Not fixed and no reply.** Leave it.

New top-level comments from others are not yours to answer. Mention them in the pass summary.

If the user has a writing-style skill, load it before drafting any reply and write in the user's voice. Replies are short and plain. Do not thank, apologise or summarize.

Then write `<SESSION_DIR>/actions.json` as `babysit-post.sh` describes: `summary` and `threads` from `threads.json` when the review pass wrote one, plus `replies` and `resolve`. On a respond pass there is no review pass, so use `SESSION_DIR="$BABYSIT_DIR/pass-<pass>"` the same way and create it. Show the output of `--dry-run` once, on the first pass of a run, so the user sees what is posted. After that post without a preview:

```bash
"$SKILL_DIR/scripts/babysit-post.sh" <number> "$SESSION_DIR/actions.json"
```

If it exits 1, show `FAILED` and the error, and do not advance the state.

When it succeeds, record the pass:

```bash
"$SKILL_DIR/scripts/babysit-state.sh" "$BABYSIT_DIR" set lastReviewedSha=<HEAD_SHA> lastSeenAt=<POLLED_AT> pass=<pass>
```

`POLLED_AT` is from the poll that started this pass, so activity that arrived during the pass is seen in the next one. Say one line: the pass number, the range reviewed, how many findings were added to the pending review, how many were held back, how many replies and resolves. If anything was added, remind the user once that the pending review is theirs to submit.

## Finish

When `STATE` is `MERGED` or `CLOSED`: tell the user which, with the number of passes, comments and resolved threads. Add the last line to the task note if you keep one. Do not start another wait.

Whenever the run ends, also when the user says stop, run `"$SKILL_DIR/scripts/workdir.sh" remove "$BABYSIT_DIR"`. It deletes the clone only when that loses nothing. If it prints `KEPT`, tell the user the directory and the reason. Then stop.

## Resume

Running `babysit <number>` again continues from `state.json`. Pending comments from the earlier run are still in the user's pending review. The clone from the earlier run is reused when it is still there, and made again when it is not. Ask the question in Start step 5 again.
