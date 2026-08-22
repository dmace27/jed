# Brief policy

## Daily brief

Use the current `planner today --json` response. Present:

1. Fixed events in start-time order.
2. Up to the configured number of focus tasks.
3. Optional work if time permits.
4. Near deadlines and explicit risks.

Say remaining effort approximately. Preserve unknown estimates as unknown. Do not derive a work schedule from gaps between events.

## Weekly brief

Use `planner week --json`. Group tasks by course or category when that improves readability. Surface deadline clusters and total known estimated work. Distinguish known workload from tasks without estimates.

## Interpretation limits

- An open overdue task is a deadline risk, not evidence of failure.
- A completed task overrides any inconsistent estimate or work log.
- Missing work logs mean unknown progress, not zero effort.
- Calendar conflicts are warnings for the user to resolve.
- Sleep, classes, gym, interviews, meetings, and social plans are context, not hard scheduling constraints.
