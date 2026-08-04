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
# Cuts a release: bumps the version, commits it, tags it, and pushes.
#
#   ./tools/packaging/release.sh              1.2.3 -> 1.2.4   (patch bump)
#   ./tools/packaging/release.sh 1.3.0        an explicit version
#   ./tools/packaging/release.sh --dry-run    show what would happen
#
# Info.plist is the single source of truth for the version. The tag is derived
# from it, never the other way round: a tag cannot change what is inside a built
# app, so letting the tag lead would allow a release named v1.2.3 containing an
# app that reports something else. The workflow enforces that they agree.
#
# Pushing the tag is what starts the signed release build.

set -euo pipefail

plist="tools/packaging/Info.plist"
dry_run="no"
requested=""

usage() {
  printf 'usage: %s [VERSION] [--dry-run]\n' "$0" >&2
  printf '  VERSION   x.y.z. Omit to bump the patch number.\n' >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run="yes"; shift ;;
    -h|--help) usage ;;
    -*) printf 'error: unknown option %s\n' "$1" >&2; usage ;;
    *)
      [ -z "$requested" ] || usage
      requested="${1#v}"        # accept either 1.2.3 or v1.2.3
      shift
      ;;
  esac
done

[ -f "$plist" ] || { printf 'error: %s not found. Run from the repository root.\n' "$plist" >&2; exit 1; }

read_key() { /usr/libexec/PlistBuddy -c "Print $1" "$plist"; }

current="$(read_key CFBundleShortVersionString)"
current_build="$(read_key CFBundleVersion)"

if [ -n "$requested" ]; then
  version="$requested"
else
  # Patch bump. Anything else is a deliberate decision and has to be typed.
  major="${current%%.*}"
  rest="${current#*.}"
  minor="${rest%%.*}"
  patch="${rest#*.}"
  case "$current" in
    *.*.*) ;;
    *) printf 'error: %s is not x.y.z; pass a version explicitly\n' "$current" >&2; exit 1 ;;
  esac
  version="$major.$minor.$((patch + 1))"
fi

case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf 'error: %s is not a valid x.y.z version\n' "$version" >&2; exit 1 ;;
esac

# The build number only ever goes up, across every version. It is what
# distinguishes two builds of the same version, and macOS treats a lower one as
# a downgrade.
build="$((current_build + 1))"
tag="v$version"

printf 'Current: %s (%s)\n' "$current" "$current_build"
printf 'Release: %s (%s)  tag %s\n\n' "$version" "$build" "$tag"

if git rev-parse "$tag" >/dev/null 2>&1; then
  printf 'error: tag %s already exists.\n' "$tag" >&2
  exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
  printf 'error: on branch %s. Releases are cut from main.\n' "$branch" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  printf 'error: the working tree has uncommitted changes.\n' >&2
  git status --short >&2
  exit 1
fi

git fetch --quiet origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  printf 'error: main and origin/main differ. Push or pull first.\n' >&2
  exit 1
fi

if [ "$dry_run" = "yes" ]; then
  printf 'Dry run. Would:\n'
  printf '  set CFBundleShortVersionString to %s and CFBundleVersion to %s\n' "$version" "$build"
  printf '  run make test\n'
  printf '  commit "Release %s"\n' "$tag"
  printf '  tag %s and push it, starting the signed release build\n' "$tag"
  exit 0
fi

# Tests run before the version is committed, so a failure leaves nothing behind.
printf 'Running tests…\n'
make test >/dev/null

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"

# PlistBuddy rewrites the whole file, so confirm it wrote what was asked before
# committing a version that might be wrong.
written_version="$(read_key CFBundleShortVersionString)"
written_build="$(read_key CFBundleVersion)"
if [ "$written_version" != "$version" ] || [ "$written_build" != "$build" ]; then
  printf 'error: the plist now reads %s (%s); expected %s (%s).\n' \
    "$written_version" "$written_build" "$version" "$build" >&2
  git checkout -- "$plist"
  exit 1
fi

git add "$plist"
git commit --quiet -m "Release $tag"
git tag -a "$tag" -m "Sandfort $version"

printf '\nAbout to push:\n'
printf '  commit %s  Release %s\n' "$(git rev-parse --short HEAD)" "$tag"
printf '  tag    %s\n' "$tag"
printf '\nPushing the tag starts the signed release build and publishes a GitHub Release.\n'
printf 'Continue? [y/N] '
read -r answer
case "$answer" in
  y|Y|yes|YES) ;;
  *)
    printf 'Stopped. Undoing the local commit and tag.\n'
    git tag -d "$tag" >/dev/null
    git reset --quiet --hard HEAD~1
    exit 1
    ;;
esac

git push --quiet origin main
git push --quiet origin "$tag"

printf '\nPushed. Watch the build:\n'
printf '  gh run watch\n'
printf 'The release will appear at:\n'
printf '  https://github.com/%s/releases/tag/%s\n' \
  "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo 'OWNER/REPO')" "$tag"
