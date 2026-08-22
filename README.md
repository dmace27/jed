# Author's Note
- - - - - 
I wanted an AI native calendar that would work if I spoke into it and manage all my
to do's and calendar without me having to do anything. Its Codex skills on top of a 
custom CLI that scrapes my current calendar and to do list and then gives me a report.


# Planner

Planner is a local, on-demand control layer over Apple Calendar and Apple Reminders. Calendar holds fixed commitments, Reminders holds obligations, and a small SQLite database holds only estimates, work logs, temporary focus overrides, and planner-linked subtasks.

It is designed for Codex to operate through typed commands. It does not run a server, poll in the background, time-block tasks, or call an AI API.

## Start here

1. Ensure the installed Apple developer toolchain can build the package. The current Command Line Tools successfully build Planner; full Xcode is needed only for the XCTest suite or if a future SDK/toolchain mismatch appears.
2. Replace the example course in `config/courses.md` with your current courses and aliases.
3. Review `config/preferences.yaml`.
4. Run `scripts/install-local.sh`.
5. Run `planner status --request-access` and grant Full Access to Calendar and Reminders.
6. Preview the dedicated Apple structure with `planner setup`, then create it with `planner setup --apply`.
7. Run `planner today`.

See `docs/SETUP.md` for the complete setup and `docs/COMMANDS.md` for the CLI contract.
