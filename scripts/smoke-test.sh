#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/planner-smoke.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

cd "$repository_root"
swift build --product planner
"$repository_root/.build/debug/planner" self-test \
    --config "$repository_root/config" \
    --db "$temporary_root/planner.sqlite" \
    --json >/dev/null

echo "Offline smoke tests passed. XCTest and live EventKit tests require full Xcode and explicit Apple permissions."
