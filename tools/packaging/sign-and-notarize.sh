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
# Developer ID signs, notarizes, and staples dist/Sandfort.app.
#
#   SANDFORT_SIGN_IDENTITY   full name of the Developer ID Application identity
#   SANDFORT_NOTARY_PROFILE  notarytool keychain profile (default: sandfort)
#
# Run `make app` first. This script never builds, so what gets notarized is
# exactly what was tested.

set -euo pipefail

app="dist/Sandfort.app"
entitlements="tools/packaging/Sandfort.entitlements"
profile="${SANDFORT_NOTARY_PROFILE:-sandfort}"

if [ ! -d "$app" ]; then
  printf 'error: %s does not exist. Run `make app` first.\n' "$app" >&2
  exit 1
fi

identity="${SANDFORT_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  # Exactly one Developer ID Application identity is the normal case; more than
  # one has to be chosen deliberately rather than guessed at.
  # Read into an array the long way: macOS ships bash 3.2, which has no mapfile.
  found=()
  while IFS= read -r line; do
    [ -n "$line" ] && found+=("$line")
  done < <(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')
  if [ "${#found[@]}" -eq 1 ]; then
    identity="${found[0]}"
  elif [ "${#found[@]}" -eq 0 ]; then
    printf 'error: no Developer ID Application certificate found.\n' >&2
    printf 'Create one in Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application.\n' >&2
    exit 1
  else
    printf 'error: several Developer ID Application certificates found. Set SANDFORT_SIGN_IDENTITY to one of:\n' >&2
    printf '  %s\n' "${found[@]}" >&2
    exit 1
  fi
fi
printf 'Signing as: %s\n' "$identity"

# Nested code signs first. --deep is deliberately not used: it is deprecated and
# applies the app's entitlements to nested bundles, which is not what any of
# them should carry.
help_bundle="$app/Contents/Resources/Sandfort.help"
if [ -d "$help_bundle" ]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$help_bundle"
fi

codesign --force --options runtime --timestamp \
  --entitlements "$entitlements" \
  --sign "$identity" "$app"

codesign --verify --strict --verbose=2 "$app"

# The entitlement is why this app can drive UTM at all. A build that loses it
# still installs and launches, and silently never starts a VM.
if ! codesign -d --entitlements - "$app" 2>/dev/null \
    | grep -q 'com.apple.security.automation.apple-events'; then
  printf 'error: the Apple Events entitlement is missing from the signed app.\n' >&2
  printf 'Sandfort would launch normally and never be able to start a VM.\n' >&2
  exit 1
fi
printf 'Apple Events entitlement present.\n'

printf 'Submitting for notarization…\n'
archive="dist/Sandfort-notarize.zip"
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
rm -f "$archive"

xcrun stapler staple "$app"
spctl --assess --type execute --verbose=4 "$app"

printf '\nSigned, notarized, and stapled: %s\n' "$app"
printf 'Verify it starts a VM before distributing it.\n'
