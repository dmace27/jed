# Commands

All commands accept `--json`, `--config PATH`, and `--db PATH`. Codex should always request JSON.

## Status and setup

```bash
planner self-test
planner status
planner status --request-access
planner setup
planner setup --apply
```

`setup` is a preview unless `--apply` is present.

`self-test` uses an in-memory Calendar/Reminders adapter and a temporary SQLite database. It never touches live Apple data.

## Briefs and queries

```bash
planner today [--date YYYY-MM-DD]
planner week [--date YYYY-MM-DD]
planner calendar today [--date YYYY-MM-DD]
planner tasks [--due-within 7d]
planner task show "title or EventKit ID"
```

Every query reads EventKit at invocation time.

## Tasks

```bash
planner task create --title TEXT [--course ALIAS | --list NAME | --category CATEGORY]
  [--due DATE_OR_DATETIME] [--estimate-minutes N] [--importance N]
  [--notes TEXT] [--parent TASK]

planner task complete TASK
planner task log TASK --minutes N [--note TEXT]
```

Course tasks go to the configured course list. Recruiting tasks default to Recruiting. Other non-course tasks default to Other while retaining their planner category in SQLite.

Date-only deadlines receive the configured due time, initially 23:59. A missing deadline or estimate stays unknown.

### Task edits

```bash
planner task preview-update TASK [OPTIONS]
planner task update TASK [OPTIONS] --confirm-change
```

Options include:

- `--title TEXT`
- `--course ALIAS` or `--list NAME`
- `--due DATE_OR_DATETIME` or `--clear-due`
- `--notes TEXT` or `--clear-notes`
- `--estimate-minutes N` or `--clear-estimate`
- `--category CATEGORY`
- `--importance N`
- `--clear-course`

### Task deletion

```bash
planner task delete TASK
planner task delete TASK --confirm-delete
```

The first command is a deletion preview. The confirmed command deletes both the Apple Reminder and its local planner metadata.

## Events

```bash
planner event create --title TEXT --start DATETIME --end DATETIME
  [--course ALIAS | --calendar NAME | --category CATEGORY]
  [--location TEXT] [--notes TEXT] [--all-day]
```

Event creation proceeds when an overlap exists and returns all detected conflicts.

```bash
planner event preview-update EVENT [OPTIONS]
planner event update EVENT [OPTIONS] --confirm-change
planner event delete EVENT
planner event delete EVENT --confirm-delete
```

Event update options include title, calendar/course/category, start, end, location, notes, `--clear-location`, and `--clear-notes`.

## Temporary focus

```bash
planner focus set --target-type task|course|category --target ID --priority 1..10
  [--from YYYY-MM-DD] [--until YYYY-MM-DD] [--reason TEXT]
```

An omitted start defaults to today. An omitted end defaults to the end of the start day. Focus overrides expire and never rewrite Apple priority fields.

## Resolution and ambiguity

Commands accept an exact EventKit identifier, an exact normalized title, or a unique partial title. Multiple matches produce an error with candidates; Planner never chooses one arbitrarily.
