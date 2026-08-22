# Shortcuts phase boundary

Apple Shortcut assets are intentionally outside v1. The local CLI must first prove useful and reliable.

When Shortcuts are added, keep them thin:

- Quick Capture may create a basic Reminder or Calendar event directly on the phone.
- A manually created phone task without planner metadata remains fully valid and appears in the next brief.
- Rich fields such as effort estimates can be added later through Codex while the Mac is awake.
- A morning automation may display or speak a brief at a user-selected time, but it must not require a new server or cloud relay.

The no-server constraint means an iPhone cannot invoke the Mac-local SQLite layer while the Mac is unavailable. Direct Apple capture remains the fallback because iCloud delivers the resulting Calendar or Reminder item to the Mac.
