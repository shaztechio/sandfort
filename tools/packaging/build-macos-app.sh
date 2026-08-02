#!/bin/bash
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
swift "$root/tools/packaging/render-help.swift" "$root/HELP.md" "$help_lproj/Sandfort.html"
hiutil -I lsm -C -ag -s en -l en -f "$help_lproj/Sandfort.helpindex" "$help_lproj"
test -s "$help_lproj/Sandfort.html"
test -s "$help_lproj/Sandfort.helpindex"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$app"
fi

printf 'Built %s\n' "$app"
printf 'For distribution, sign and notarize the app with your Apple Developer identity.\n'
