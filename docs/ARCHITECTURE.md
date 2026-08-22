# Architecture

## Ownership

Apple Calendar and Reminders are the source of truth for user-visible items. The system reads all visible calendars and lists when preparing advice. New items default to dedicated Planner destinations, while an explicit user request may edit an item elsewhere after confirmation.

SQLite contains no mirrored titles, due dates, completion flags, or event rows. It holds only properties that Apple does not represent for this workflow.

## Components

```text
Codex productivity skill
        |
        v
planner CLI --json
        |
        +-------------------+
        |                   |
        v                   v
EventKitCalendarStore   SQLiteMetadataStore
        |                   |
Calendar + Reminders   effort and focus context
```

`EventKitCalendarStore` is an actor with one `EKEventStore`. This avoids mixing EventKit objects across stores and serializes access to framework objects.

`PlannerEngine` is pure and deterministic. It can be tested without Calendar permission. It prioritizes overdue and near-due work, then incorporates configured category priority, a temporary focus override, Apple priority, and known remaining effort.

`PlannerService` joins fresh EventKit objects to planner metadata by EventKit identifier. If iCloud changes a reminder identifier, the service may reconcile metadata using EventKit's external identifier. It never restores a stale Apple field.

## Mutation safety

Creates, completion, and work logging correspond directly to a specific user instruction and do not require a second gate.

Updates produce a field-level preview and require `--confirm-change`. Deletions show the exact identifier/title and require `--confirm-delete`. Event creation and movement report overlapping events but do not impose a hard constraint.

## Privacy and execution

Planner has no network client, listening socket, scheduled job, or background poller. It is executed on demand and exits after each command. iCloud synchronization is performed by Apple's Calendar and Reminders infrastructure, not by Planner.
