#!/bin/bash
# Copyright 2026 Sandfort contributors
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

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
qualification_profile_id="${SANDFORT_QUALIFICATION_PROFILE_ID:-}"
qualification_distribution="${SANDFORT_QUALIFICATION_DISTRIBUTION:-Fedora}"
if [[ -n "$qualification_profile_id" ]]; then
  app="$root/dist/Sandfort $qualification_distribution Qualification.app"
else
  app="$root/dist/Sandfort.app"
fi
legacy_app="$root/dist/Sandbox VM.app"
contents="$app/Contents"
help_book="$contents/Resources/Sandfort.help"
help_lproj="$help_book/Contents/Resources/en.lproj"
module_cache="$root/.build/module-cache"

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

cd "$root"
swift build -c release --disable-sandbox

rm -rf "$app"
if [[ -z "$qualification_profile_id" ]]; then
  rm -rf "$legacy_app"
fi
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$root/.build/release/SandfortApp" "$contents/MacOS/SandfortApp"
cp "$root/tools/packaging/Info.plist" "$contents/Info.plist"
if [[ -n "$qualification_profile_id" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Sandfort $qualification_distribution Qualification" "$contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Sandfort $qualification_distribution Qualification" "$contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.sandfort.Sandfort.${qualification_distribution}Qualification" "$contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SandfortQualificationProfileID string $qualification_profile_id" "$contents/Info.plist"
fi
cp "$root/assets/Sandfort.icns" "$contents/Resources/Sandfort.icns"
mkdir -p "$help_lproj" "$help_book/Contents/Resources/shrd"
cp "$root/tools/packaging/SandfortHelp-Info.plist" "$help_book/Contents/Info.plist"
cp "$root/tools/packaging/SandfortHelp-InfoPlist.strings" "$help_lproj/InfoPlist.strings"
cp "$root/assets/Sandfort.png" "$help_book/Contents/Resources/shrd/Sandfort.png"

# Help Viewer resolves a book by identifier, so every installed Sandfort build
# needs its own. Sharing one identifier across the production and qualification
# apps makes helpd serve whichever registration it indexed last, which shows up
# as a blank Help window.
if [[ -n "$qualification_profile_id" ]]; then
  help_identifier="app.sandfort.help.${qualification_distribution}Qualification"
  help_title="Sandfort $qualification_distribution Qualification Help"
else
  help_identifier="app.sandfort.help"
  help_title="Sandfort Help"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $help_identifier" "$help_book/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $help_title" "$help_book/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :HPDBookTitle $help_title" "$help_book/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleHelpBookName $help_identifier" "$contents/Info.plist"

# Keep the help book's version in step with the app. helpd caches a registered
# book by identifier and version, so a frozen version makes it keep serving
# stale content after the help source changes.
app_short_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$contents/Info.plist")"
app_build_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_short_version" "$help_book/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build_version" "$help_book/Contents/Info.plist"

swift "$root/tools/packaging/render-help.swift" "$root/HELP.md" "$help_lproj/Sandfort.html" "$help_identifier"
hiutil -I lsm -C -ag -s en -l en -f "$help_lproj/Sandfort.helpindex" "$help_lproj"
test -s "$help_lproj/Sandfort.html"
test -s "$help_lproj/Sandfort.helpindex"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$app"
fi

printf 'Built %s\n' "$app"
printf 'For distribution, sign and notarize the app with your Apple Developer identity.\n'
