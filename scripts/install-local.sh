#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_root="$HOME/Library/Application Support/Planner"
skill_destination="$HOME/.codex/skills/productivity"

"$repository_root/scripts/build.sh"

install -d "$HOME/Applications" "$HOME/.local/bin" "$runtime_root/config" "$HOME/.codex/skills"
ditto "$repository_root/build/Planner.app" "$HOME/Applications/Planner.app"
install -m 755 "$repository_root/Support/planner-wrapper" "$HOME/.local/bin/planner"

if [ ! -f "$runtime_root/config/preferences.yaml" ]; then
    install -m 644 "$repository_root/config/preferences.yaml" "$runtime_root/config/preferences.yaml"
fi
if [ ! -f "$runtime_root/config/courses.md" ]; then
    install -m 644 "$repository_root/config/courses.md" "$runtime_root/config/courses.md"
fi
if [ ! -e "$skill_destination" ]; then
    ln -s "$repository_root/skills/productivity" "$skill_destination"
fi

echo "Installed Planner.app, planner CLI wrapper, runtime configuration, and Codex skill."
echo "Ensure $HOME/.local/bin is on PATH, then run: planner status --request-access"
