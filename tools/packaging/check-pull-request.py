#!/usr/bin/env python3
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

"""Checks a pull request title, and that a guest-side change says so.

    PR_TITLE=... PR_BODY=... check-pull-request.py [changed-file ...]

Merges squash, so the title becomes the commit subject and then a line in the
release notes. It is the only part of a pull request that outlives it.
"""

import os
import re
import sys

TYPES = ["feat", "fix", "docs", "refactor", "perf", "test", "build", "ci",
         "chore", "revert"]

SUBJECT = re.compile(
    r"^(?P<type>[a-z]+)"
    r"(?:\((?P<scope>[a-z0-9-]+)\))?"
    r"(?P<breaking>!)?"
    r": (?P<description>.+)$"
)

# Anything embedded in the guest. A change here forces every existing user to
# Rebuild; a new binary alone is not enough.
GUEST_SIDE = re.compile(r"sources/sandfortapp/(.*CloudInit|GuestProvisioningSupport)\.swift$")

MAX_TITLE = 72


def check_title(title):
    problems = []
    match = SUBJECT.match(title)
    if not match:
        problems.append(
            f'"{title}" is not a Conventional Commit subject.\n'
            f"      Expected: type(optional-scope): description\n"
            f"      Types: {', '.join(TYPES)}"
        )
        return problems, None

    if match.group("type") not in TYPES:
        problems.append(
            f'"{match.group("type")}" is not a type in use. '
            f"Use one of: {', '.join(TYPES)}"
        )

    description = match.group("description")
    if description[0].isupper():
        problems.append(f'Description should not start with a capital: "{description}"')
    if description.endswith("."):
        problems.append("Description should not end with a full stop.")
    if len(title) > MAX_TITLE:
        problems.append(
            f"Title is {len(title)} characters; keep it under {MAX_TITLE} so it "
            "reads as a changelog line."
        )
    return problems, match


def check_rebuild(match, body, changed):
    """A guest-side change must say whether users need to Rebuild."""
    guest_files = [f for f in changed if GUEST_SIDE.search(f)]
    if not guest_files:
        return []

    declared_breaking = bool(match and match.group("breaking")) or "BREAKING CHANGE:" in body
    declared_safe = "No rebuild required:" in body
    if declared_breaking or declared_safe:
        return []

    listed = "\n".join(f"        {f}" for f in guest_files)
    return [
        "This changes guest provisioning:\n"
        f"{listed}\n"
        "      A change there forces every existing user to Rebuild, and a new\n"
        "      binary alone is not enough. Say which it is:\n"
        "        - add ! to the type and a 'BREAKING CHANGE: ...' footer, or\n"
        "        - put 'No rebuild required: <why>' in the description."
    ]


def main(argv):
    title = os.environ.get("PR_TITLE", "").strip()
    body = os.environ.get("PR_BODY", "")
    changed = argv[1:]

    if not title:
        sys.stderr.write("error: PR_TITLE is empty\n")
        return 1

    problems, match = check_title(title)
    problems += check_rebuild(match, body, changed)

    if problems:
        sys.stderr.write("Pull request needs changes before it can merge:\n\n")
        for problem in problems:
            sys.stderr.write(f"  ✗ {problem}\n\n")
        sys.stderr.write(
            "The title becomes the commit subject and a release note line.\n"
            "See CONTRIBUTING.md.\n"
        )
        return 1

    sys.stdout.write(f"Title is fine: {title}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
