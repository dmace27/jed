# Data model

## task_metadata

One optional metadata row per Reminder touched by Planner.

- `reminder_id`: current EventKit identifier and primary key
- `external_identifier`: reconciliation fallback when iCloud changes the primary identifier
- `estimated_minutes`: nullable advisory estimate
- `category`: planner category
- `course_id`: nullable configured course ID
- `importance`: explicit per-task priority adjustment; zero means use category defaults
- `notes`: planner-only notes
- timestamps

## work_sessions

Append-only positive-minute observations. Remaining work is `max(estimated_minutes - sum(work_sessions.minutes), 0)` when an estimate exists. Completion in Apple Reminders remains authoritative regardless of the logged total.

## priority_overrides

Time-bounded priority values for a task, course, or category. Overrides affect ranking only and never alter Calendar or Reminders fields.

## task_relations

Links two independent Apple Reminders as parent and child. EventKit does not expose native Reminders nesting, so Planner renders linked children hierarchically while the Apple app shows ordinary reminders.

## Intentionally absent

There are no Calendar-event rows, Reminder mirrors, daily snapshots, health observations, inferred mood, attendance history, notification queues, or AI conversation logs.
