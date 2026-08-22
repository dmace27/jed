# Setup

## 1. Verify the Apple developer toolchain

Planner requires Swift, the macOS SDK, EventKit, and an application bundle with Calendar and Reminders privacy strings. The Command Line Tools currently installed on this Mac successfully build both debug and release Planner binaries. Verify them with:

```bash
swift --version
scripts/build.sh
```

Install full Xcode compatible with macOS Tahoe if the build reports an SDK/compiler mismatch or if you want to run the XCTest suite. After installing it, select it with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

## 2. Configure courses and preferences

Edit `config/courses.md` before installation. Every course gets one Calendar named `Class • <Course>` and one Reminders list named `<Course>`.

Use Apple Reminders' built-in **All** view to see tasks across the separate course, Recruiting, and Other lists. Planner does not create duplicate reminders in a synthetic total list.

Edit `config/preferences.yaml` if the timezone, default deadline, planning windows, or priority defaults should change.

## 3. Build and install locally

```bash
scripts/install-local.sh
```

This performs only local installation:

- builds and ad-hoc signs `Planner.app`;
- installs it in `~/Applications/Planner.app`;
- installs a wrapper at `~/.local/bin/planner`;
- copies initial configuration into `~/Library/Application Support/Planner/config` without overwriting existing runtime configuration;
- links the repository skill into `~/.codex/skills/productivity` when no skill already exists there.

Add `~/.local/bin` to `PATH` if needed.

After installation, make user-specific changes in the runtime configuration directory. Re-running the installer deliberately does not overwrite those files.

## 4. Grant Apple permissions

Run:

```bash
planner status --request-access
```

Grant Planner Full Access to Calendar and Reminders. Full access is required because daily briefs read current data and user-requested actions can create, edit, complete, and delete items.

If access was denied, enable it under System Settings → Privacy & Security → Calendars and Reminders, then run `planner status`.

## 5. Create dedicated calendars and lists

Preview first:

```bash
planner setup
```

Apply once:

```bash
planner setup --apply
```

The operation is idempotent by normalized title. Existing writable calendars/lists with the expected name are reused.

## 6. Verify without mutating data

```bash
planner self-test
planner status
planner calendar today
planner tasks
planner today
```

Manual Calendar or Reminders edits are visible on the next query; Planner does not maintain a background cache.

Repository contributors can run `scripts/smoke-test.sh`. After full Xcode is selected, `swift test` additionally runs the XCTest suite.

## Runtime files

```text
~/Library/Application Support/Planner/
├── config/
│   ├── courses.md
│   └── preferences.yaml
└── planner.sqlite
```

The database is not encrypted or automatically backed up. Calendar and Reminders continue to sync through their configured Apple accounts. Planner metadata remains local to this Mac.
