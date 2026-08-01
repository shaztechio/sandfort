#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$root/dist/Sandfort.app"
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

rm -rf "$app" "$legacy_app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$root/.build/release/SandfortApp" "$contents/MacOS/SandfortApp"
cp "$root/tools/packaging/Info.plist" "$contents/Info.plist"
cp "$root/Assets/Sandfort.icns" "$contents/Resources/Sandfort.icns"
mkdir -p "$help_lproj" "$help_book/Contents/Resources/shrd"
cp "$root/tools/packaging/SandfortHelp-Info.plist" "$help_book/Contents/Info.plist"
cp "$root/tools/packaging/SandfortHelp-InfoPlist.strings" "$help_lproj/InfoPlist.strings"
cp "$root/Assets/Sandfort.png" "$help_book/Contents/Resources/shrd/Sandfort.png"
swift "$root/tools/packaging/render-help.swift" "$root/HELP.md" "$help_lproj/Sandfort.html"
hiutil -I lsm -C -ag -s en -l en -f "$help_lproj/Sandfort.helpindex" "$help_lproj"
test -s "$help_lproj/Sandfort.html"
test -s "$help_lproj/Sandfort.helpindex"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$app"
fi

printf 'Built %s\n' "$app"
printf 'For distribution, sign and notarize the app with your Apple Developer identity.\n'
