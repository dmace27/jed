# Planner command contract

## Read operations

Always append `--json` when Codex consumes output.

```bash
planner status --json
planner today --json
planner week --json
planner calendar today --json
planner tasks --json
planner tasks --due-within 7d --json
planner task show "task title or ID" --json
```

## Task creation and progress

```bash
planner task create --title "CS assignment" --course cs135 \
  --due 2026-09-18 --estimate-minutes 360 --json

planner task create --title "Draft introduction" --course cs135 \
  --parent "CS assignment" --json

planner task complete "task title or ID" --json
planner task log "task title or ID" --minutes 75 --note "practice problems" --json
```

A date-only due value uses the configured 23:59 local deadline. Use `YYYY-MM-DDTHH:mm` when the user supplies a time. Do not supply an estimate when the user did not provide one.

Use `--course ALIAS` for configured courses. Otherwise use `--category academics|health|recruiting|clubs|social|personal|other`; recruiting goes to the Recruiting list and other non-course categories go to Other.

## Event creation

```bash
planner event create --title "Interview" --category recruiting \
  --start 2026-09-18T14:00 --end 2026-09-18T15:00 --json
```

Use Calendar only for an event with a real start and end. Report `conflicts` returned by the command, but do not automatically undo the event.

## Protected mutations

First preview:

```bash
planner task preview-update "task title or ID" --due 2026-09-19 --json
planner event preview-update "event title or ID" --start 2026-09-18T15:00 --json
planner task delete "task title or ID" --json
planner event delete "event title or ID" --json
```

After the user confirms the displayed target and change, rerun with the corresponding gate:

```bash
planner task update "task ID" --due 2026-09-19 --confirm-change --json
planner event update "event ID" --start 2026-09-18T15:00 --confirm-change --json
planner task delete "task ID" --confirm-delete --json
planner event delete "event ID" --confirm-delete --json
```

Never infer confirmation from an earlier, materially different requested change.

## Temporary focus

```bash
planner focus set --target-type category --target recruiting --priority 6 \
  --from 2026-09-14 --until 2026-09-20 --reason "recruiting week" --json
```

Priorities range from 1 through 10. Temporary overrides expire automatically.
