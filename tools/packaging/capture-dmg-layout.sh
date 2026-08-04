#!/bin/bash
# Copyright 2026 Shazron Abdullah and Sandfort contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Regenerates tools/packaging/dmg-layout.DS_Store, the window arrangement that
# make-dmg.sh replays.
#
#   ./tools/packaging/capture-dmg-layout.sh
#
# Run this on a Mac with a desktop session; it drives Finder, and a volume has
# to be mounted where Finder can see it. That is exactly why the result is
# committed: the build then needs nothing but hdiutil, and CI never touches
# Finder.
#
# It reads the settings back before saving. Finder accepts an icon size and
# silently keeps the old one often enough that writing the file without checking
# produced a layout with 48-point icons where 128 was asked for.

set -euo pipefail

app="dist/Sandfort.app"
layout="tools/packaging/dmg-layout.DS_Store"
volume="Sandfort"

# Window is 600x420. Icon centres sit on the same baseline, a third and
# two-thirds across, leaving the middle clear for a background arrow.
window_bounds="{200, 150, 800, 570}"
icon_size=128
app_position="{150, 195}"
applications_position="{450, 195}"

[ -d "$app" ] || { printf 'error: %s does not exist. Run `make app` first.\n' "$app" >&2; exit 1; }

staging="$(mktemp -d)"
image="$(mktemp -d)/layout.dmg"
cleanup() {
  hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true
  rm -rf "$staging" "$(dirname "$image")"
}
trap cleanup EXIT

ditto "$app" "$staging/Sandfort.app"
ln -s /Applications "$staging/Applications"

hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true
hdiutil create -volname "$volume" -srcfolder "$staging" -format UDRW -ov -quiet "$image"
hdiutil attach "$image" -quiet
sleep 2

# The read-back happens inside this same block, before the window closes.
# Asking again in a second Finder session reports defaults, not what was stored,
# which made an earlier version of this check pass and fail at random.
actual="$(osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to $window_bounds
    -- Assign through the container window each time. Binding the options to a
    -- variable first takes a snapshot: the assignments appear to succeed, Finder
    -- keeps its old values, and the captured layout silently has 48-point icons.
    set arrangement of the icon view options of container window to not arranged
    set icon size of the icon view options of container window to $icon_size
    set text size of the icon view options of container window to 13
    delay 1
    set position of item "Sandfort.app" of container window to $app_position
    set position of item "Applications" of container window to $applications_position
    delay 1
    update without registering applications
    delay 3
    set stored to (icon size of the icon view options of container window as text)
    close
    return stored
  end tell
end tell
APPLESCRIPT
)"

sleep 2

if [ "$actual" != "$icon_size" ]; then
  printf 'error: Finder stored an icon size of %s, not %s.\n' "$actual" "$icon_size" >&2
  printf 'The layout was not captured. Close any Finder windows on the volume and retry.\n' >&2
  exit 1
fi

sync
cp "/Volumes/$volume/.DS_Store" "$layout"
hdiutil detach "/Volumes/$volume" -quiet

printf 'Captured %s\n' "$layout"
printf '  icon size %s, window %s\n' "$icon_size" "$window_bounds"
printf '  Sandfort.app at %s, Applications at %s\n' "$app_position" "$applications_position"
printf '\nRebuild the image with `make dmg` and check it looks right.\n'
