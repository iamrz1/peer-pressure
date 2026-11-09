# Urgency

How hard to push for each finding. Severity (the label and score) says how bad the problem is. Urgency says how hard a reviewer would push. They can differ.

| Urgency | Meaning |
|---|---|
| `insist` | Insist on the fix before merging. Shipping it would break something, lose data, open a hole, or make a later fix much harder. |
| `ask` | Ask for the fix in this PR. Merging first would not hurt, but it is cheap to fix now and likely to be forgotten later. The author may push back with a reason. |
| `author` | Up to the author. Worth doing, and the author decides whether to fix it here or later. |
| `optional` | Nice to have. Fine to ignore, no ticket needed. |

Do not copy the label into the urgency. Weigh these:

- Is the problem in code this change adds, or in code that was already there?
- How far does it reach if it goes wrong: one caller, one service, all users?
- How big and how risky is the fix? A one-line fix for a medium problem is `ask`. A large refactor for the same problem is `author`.
- Does the fix touch code the change is already changing?
- Is it likely to be forgotten or to get worse if left?
- Do the scores agree across lenses, or did only one lens care?

Be consistent: findings with the same facts get the same urgency. Use the whole range. Not every critical finding is `insist`, and not every suggestion is `optional`.

Give each finding one plain sentence as the `reason`. It names the deciding fact, not the severity.

## Output

Where the urgency is written as its own file (`triage.json`), it is a JSON array with one object per finding, in the order of the findings:

```
{"id": "F1", "urgency": "insist", "reason": "One sentence on why you would push this hard."}
```

`id` must match the finding. `urgency` is one of `insist`, `ask`, `author`, `optional`. Escape quotes so the file is valid JSON. With no findings, write `[]`.
