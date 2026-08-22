## Project guidelines

- Keep Apple Calendar and Apple Reminders authoritative for events, tasks, deadlines, and completion state.
- Query EventKit on demand; do not add background polling or mirror Apple data into SQLite.
- Store only planner-specific metadata in SQLite: estimates, work logs, temporary focus overrides, and task relationships.
- Require an explicit confirmation flag for edits and deletions. Creates, completions, and work logs may execute directly after a specific user instruction.
- Keep planning advisory. Never time-block reminder tasks or create notifications unless the user explicitly requests that behavior.
- Write readable, documented code and explain non-obvious safety decisions with comments.
