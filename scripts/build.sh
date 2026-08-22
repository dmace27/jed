#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_directory="$repository_root/build/Planner.app"

cd "$repository_root"
swift build -c release

install -d "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
install -m 755 ".build/release/planner" "$app_directory/Contents/MacOS/planner"
install -m 644 "Support/Info.plist" "$app_directory/Contents/Info.plist"
codesign --force --sign - --identifier local.danielmace.planner "$app_directory"

echo "Built $app_directory"
