---
description: Append a task to todo.md
argument-hint: <task>
---
Append `$ARGUMENTS` as a new top-level bullet at the end of `todo.md` in the repo root.

- Add exactly one line: `- $ARGUMENTS` after the current last line.
- Preserve every existing line, its wording, order, and indentation — do not reformat or reorder anything.
- If `todo.md` doesn't exist, create it with that single bullet.
- Do not implement the task or make any other code changes; this only records it.

Then reply with one short line confirming what was added.
