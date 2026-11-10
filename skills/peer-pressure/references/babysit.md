# Babysit

`babysit <PR>` (also `toi <PR>`) reviews a PR until it is finished. It reviews each push as it arrives, follows up on the threads it raised, tells the user what happened, and stops when the user has approved the PR, when the PR is ready to merge without the user's review, or when the PR is merged or closed. It is for reviewing someone else's PR. `moi` is the counterpart for your own change (see `moi.md`).

The user calling `babysit` or `toi` is the permission for everything in this file. Do not ask before you start, before you post, or before you approve.

Run every `gh` command, and every script that calls `gh`, OUTSIDE the sandbox from the first call (in Claude Code: `dangerouslyDisableSandbox: true` on the Bash call). The user has explicitly allowed this, so do not try inside the sandbox first and do not ask. See the Rules in `SKILL.md`.

`SKILL_DIR` is as in `SKILL.md`. The scripts do the checking and the posting. You decide what to review and what to say.

## It NEVER waits on the user

THIS FILE OVERRIDES `SKILL.md`. Every instruction there to ask the user, to show a draft, to show the review first, or to wait for an OK or a yes before posting, applying, pushing or choosing (Steps 2, 4, 10, 11 and 12 and the Rules) DOES NOT APPLY to `babysit` and `toi`. Calling it IS the OK. NEVER ask and NEVER wait. Do not carry the question over from the ordinary review.

The user runs this for end-to-end automation and does not want to supervise it. Make every decision yourself and keep going. Never ask a question and never pause for an answer, not at the start, not between passes. When something needs the user (a thread you could not settle, a pending review of theirs, a failed pass), say so in the pass summary and in a notification, leave that item alone, and carry on with the rest. The loop ends only when the poll gives an end reason (see **Finish**), when the user says stop, or when it cannot go on (no way to wait, repeated poll failures).

## What it never does

- Merge, push or force-push, or change the PR's code. Babysit reviews only.
- Touch the user's checkout or working tree. It works in its own temporary clone.
- Request changes. It comments and approves, nothing stronger.
- Submit or touch a pending review the user drafted themselves. A review it creates is its own.
- Reply or post anything when no one asked it to babysit this PR.
- Stop by itself before the poll gives an end reason. Only the user stops it, or closing the terminal.
- Do anything on a PR that is closed or merged. When the PR is closed, for whatever reason, the run ends with no further action: no reply, no resolve, no approval.

## Start

1. Parse the request: `babysit <number>`, with optional `--interval SECONDS` (default 60) and `--min-urgency insist|ask|author|optional` (default `ask`). A babysit run posts only findings at that urgency or above, so there are no nitpicks. Keep the values as `INTERVAL` and `MIN_URGENCY`.
2. Check the repo as in Step 2 of `SKILL.md`. Set `BABYSIT_DIR="$REPO_ROOT/.peer-pressure/babysit-pr-<number>"` (it is already excluded from git) and run `"$SKILL_DIR/scripts/babysit-state.sh" "$BABYSIT_DIR" init <number> <owner/repo>`. If the state already existed, tell the user you are resuming and from which pass.

   The state and the session files stay in `BABYSIT_DIR`, in the user's repo, so that a closed terminal does not lose them. The code is read in a temporary clone: if `"$SKILL_DIR/scripts/workdir.sh" path "$BABYSIT_DIR"` prints a directory, reuse it. Otherwise run `"$SKILL_DIR/scripts/workdir.sh" create <number> <owner/repo> "$BABYSIT_DIR" --read-only`. Keep `WORKDIR`. It is the PR's head, checked out detached. The user's own checkout can be on any branch and in any state.
3. Run `"$SKILL_DIR/scripts/babysit-poll.sh" <number> "$BABYSIT_DIR"`. If `ACTION` is `done`, go to **Finish** now: a PR that is closed, merged, already approved by the user or already ready needs no run. If `VIEWER` equals `AUTHOR`, say that babysit reviews other people's PRs and stop.
4. Do not write to `~/memory/`. The state file is the record.
5. Say one line and go on: "Babysitting PR #<number>. I review each push, post findings (<MIN_URGENCY> and above) and replies, resolve my threads when the fix is in, and approve when there is nothing to raise. I never merge, push or request changes. Tell me to stop at any time." Do not wait for an answer. Calling `babysit` covers this PR for this run, and not another PR.

## The loop

Repeat until `ACTION` is `done` or the user says stop.

1. Poll: `"$SKILL_DIR/scripts/babysit-poll.sh" <number> "$BABYSIT_DIR"`. Keep the output and `poll.json`. Follow `ACTION`:
   - `done`: go to **Finish**.
   - `review`: do a **Review pass**, then a **Thread pass**.
   - `respond`: do a **Thread pass**.
   - `idle`: go to step 3.
2. Wait: run `"$SKILL_DIR/scripts/babysit-wait.sh" <number> "$BABYSIT_DIR" --interval <INTERVAL>` and go back to step 1 when it returns. It returns when something changed, after 30 minutes, or after five failed polls (`WAIT=error`: tell the user and keep trying every few minutes).
   - If you can run a command in the background, run it there, so that you are called again when it exits. Do not poll its output.
   - If you cannot, run it in the foreground with `--max` below the host's command time limit.
   - If you cannot wait at all, do one pass, tell the user the run is not continuous here, and stop.

Notify the user with the host's notification tool when there is one, and always print the line in the terminal. Notify when: a pass posted something, you approved, a thread needs the user's decision, a pass failed, and the run ended.

## Review pass

Review what changed since the last review, not the whole PR again. Run every `git` and `gh` command and every script from `WORKDIR`, so that `gh` resolves the PR's repo. Wherever Steps 3 to 8 of `SKILL.md` give the repository to read, give `WORKDIR`, not the user's checkout.

1. `SESSION_DIR="$BABYSIT_DIR/pass-<pass>"`, where `<pass>` is the `pass` value in the state plus one. Run `"$SKILL_DIR/scripts/workdir.sh" sync "$BABYSIT_DIR"` to bring the clone to the current head. Then, from `WORKDIR`, run `"$SKILL_DIR/scripts/babysit-delta.sh" <number> "$BABYSIT_DIR" "$SESSION_DIR"`. Keep `DELTA` and `FROM_SHA`.
   - `none`: nothing to review. Go to the **Thread pass**.
   - `full`: the first pass, or the branch was force-pushed. Review the whole PR and say which.
2. Follow Steps 3 to 8 of `SKILL.md` with `input.txt` as the change, with these differences:
   - `PRIOR_PREAMBLE` is always set, because your own threads exist. Do not report again what is already open or resolved.
   - For an incremental delta, add to the preamble: "This is the change since commit <FROM_SHA>. Review only this change. Code outside it is out of scope unless this change breaks it."
   - In Step 8, run `build-report.sh "$SESSION_DIR" --min-urgency "$MIN_URGENCY"`. Keep how many findings were held back.
3. If the report has findings, follow Step 12.1 of `SKILL.md` to write `<SESSION_DIR>/threads.json`, with the delta as the diff. Do not post yet. The **Thread pass** posts everything once. Skip Step 12.2 to 12.4: there is no preview and no question.

If the pass fails, do not advance the state. The next poll tries again. After two failures on the same head, note it in the notification and keep watching for a new push.

## Thread pass

Before you post anything, check that the PR is still open: `gh pr view <number> --json state --jq .state`. If it is not `OPEN`, post nothing and go to **Finish**.

Look at the threads in `poll.json`: `ownThreads` (threads you or the user raised that are still open) and `newReplies`. Read only those, and the code at the head they point to.

For each own thread, decide from the code, not from what anyone says:

- **Fixed.** The problem is gone at the head. Reply in one short line that names the commit (`Fixed in <short sha>.`), and add the thread to `resolve`.
- **The author gave a reason.** Check the reason against the code. If they are right, reply in one line that you agree, and resolve. If they are wrong, reply once with the evidence and leave the thread open.
- **Still disagreeing after two of your replies.** Do not reply again. Note it in the pass summary and the notification, leave the thread open, and go on.
- **A question you can answer from the code.** Answer it in one or two sentences. If you cannot, leave it, note it in the pass summary and go on.
- **Not fixed and no reply.** Leave it.

New top-level comments from others are not yours to answer. Mention them in the pass summary.

If the user has a writing-style skill, load it before drafting any reply or finding and write in the user's voice. Replies are short and plain. Do not thank, apologise or summarize.

**Approve.** When the review has nothing to raise and the PR still needs a review from the user or the user's team, approve the PR. That means all of these hold after this pass: `needsMyReview` in `poll.json` is `true` (when it is `false`, do not approve: the required approvals are in, and the next poll ends the run as `ready`), `threads.json` is empty or absent, every own thread is resolved (those in `resolve` count), the PR is not a draft, `CI` is not `failing`, the head is the one you reviewed (`lastReviewedSha` will equal `HEAD_SHA`), and `babysit-state.sh "$BABYSIT_DIR" get approvedSha` is not `<HEAD_SHA>`. Then add `"approve": "<message>"` to the actions. The message is short, in the user's voice: `LGTM` or `✅ Looks good`, with at most one plain line about what the PR does. Never an empty message. Never approve in the same pass that posts new threads.

Then write `<SESSION_DIR>/actions.json` as `babysit-post.sh` describes: `summary` and `threads` from `threads.json` when the review pass wrote one, plus `replies`, `resolve` and `approve`. On a respond pass there is no review pass, so use `SESSION_DIR="$BABYSIT_DIR/pass-<pass>"` the same way and create it. Post it, with no preview. New threads go out as one review of type comment, replies and resolves take effect at once:

```bash
"$SKILL_DIR/scripts/babysit-post.sh" <number> "$SESSION_DIR/actions.json"
```

If it exits 1, show `FAILED` and the error, and do not advance the state. If `approve` was set and the output says `APPROVED=false`, the viewer has a pending review of their own. Tell the user once that you did not approve because of it, and do not retry on this head.

When it succeeds, record the pass. When `APPROVED=true`, also set `approvedSha=<HEAD_SHA>`:

```bash
"$SKILL_DIR/scripts/babysit-state.sh" "$BABYSIT_DIR" set lastReviewedSha=<HEAD_SHA> lastSeenAt=<POLLED_AT> pass=<pass>
```

`POLLED_AT` is from the poll that started this pass, so activity that arrived during the pass is seen in the next one. Say one line: the pass number, the range reviewed, how many findings were posted, how many were held back, how many replies and resolves, and whether you approved.

## Finish

The poll's `END_REASON` says why the run is over. Say it in one line, with the number of passes, comments and resolved threads, and do not start another wait:

- `merged` or `closed`: say which. Take no other action: nothing is posted, replied to, resolved or approved.
- `approved`: the user's latest review is an approval. It may be one you posted in the last pass, or the user's own. The job is done.
- `ready`: the PR has the approvals the repo requires, from others, and nothing is needed from the user or the user's teams. CI is passing, nothing is open and the last push was reviewed. The job is done. Do not approve.
- `not-needed`: the PR only waits for reviewers other than the user and the user's teams. Nothing is left for you to do, so the run ends. Say that the PR is not ready to merge yet and who it waits for (`reviewRequests`).

Whenever the run ends, also when the user says stop, run `"$SKILL_DIR/scripts/workdir.sh" remove "$BABYSIT_DIR"`. It deletes the clone only when that loses nothing. If it prints `KEPT`, tell the user the directory and the reason. Then stop.

## Resume

Running `babysit <number>` again continues from `state.json`. If the PR has ended in the meantime, the first poll says so and the run finishes at once. The clone from the earlier run is reused when it is still there, and made again when it is not.
