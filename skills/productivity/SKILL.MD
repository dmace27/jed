---
name: productivity
description: Manage the user's local Apple Calendar and Apple Reminders through the repository's planner CLI. Use for natural-language requests to review today's work, inspect upcoming deadlines, create or complete tasks, log work, create fixed events, preview or apply edits/deletions, set temporary priorities, or summarize the next two weeks. Also use for daily and weekly productivity briefs involving classes, recruiting, health commitments, clubs, social events, or personal tasks.
---

# Productivity

Treat Apple Calendar and Apple Reminders as authoritative. Query them fresh for every request. Use SQLite only for estimates, work logs, temporary focus overrides, and planner-linked subtasks.

## Locate the command

Run `command -v planner`. If unavailable, locate the repository root and use its installed app after following `docs/SETUP.md`. Do not add an API service or background process.

Read `config/courses.md` when resolving a course name or alias. Read `config/preferences.yaml` when interpreting priorities, planning windows, or the default due time.

## Execute requests

1. Translate the user's natural language into one or more typed `planner` commands. Never pass natural language to a hidden model or invent a `planner ask` command.
2. Use `--json` for all machine-readable queries and mutations.
3. Query current state before resolving a title. Prefer the exact EventKit identifier returned by the query.
4. Ask one concise clarification when a task, event, course, date, or time remains ambiguous. Never guess among multiple matches.
5. Execute creates, completions, and work logs after a specific user instruction.
6. Preview every edit or deletion. Show the diff or deletion target and obtain confirmation before rerunning with `--confirm-change` or `--confirm-delete`.
7. Re-query after a mutation and report the resulting Apple state plus any overlap warning.

Read [references/command-contract.md](references/command-contract.md) for exact commands and field rules. Read [references/brief-policy.md](references/brief-policy.md) before producing daily or weekly advice.

## Preserve the operating philosophy

- Keep Calendar for fixed commitments and Reminders for obligations.
- Never create study or work time blocks unless the user explicitly asks for a fixed event.
- Rank tasks and estimate workload without choosing the hour in which the user must work.
- Treat health and academics as equal default priorities, followed by recruiting, clubs, and personal work. Apply these as defaults rather than laws.
- Treat manual Apple edits as authoritative. Never restore an older title, deadline, list, calendar, or completion state from SQLite.
- Leave an unfinished task open when the user says they did not get to it. Let its deadline affect the next brief.
- Do not infer health, mood, energy, attendance, or productivity from missing work logs.
- Do not create notifications, reminders about reminders, or unsolicited follow-ups.

## Handle common statements

- "What do I need to do today?" → run `planner today --json`, then give a flexible summary without time blocking.
- "CS assignment due Friday, about six hours" → resolve the CS alias and create a course task with a due datetime and `--estimate-minutes 360`.
- "Worked on math for 75 minutes" → query tasks, resolve exactly, then log 75 minutes.
- "I submitted X" → resolve the open task and complete it.
- "I finished X, worked two hours on Y, and didn't get to Z" → complete X, log 120 minutes on Y, and leave Z unchanged.
- "Focus recruiting this week" → create a temporary category focus override for the requested date range.
- "Move the interview to 3 PM" → preview the event update, show conflicts and the diff, and wait for confirmation.
