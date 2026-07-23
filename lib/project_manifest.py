#!/usr/bin/env python3
"""Strictly validate a .beam-debug.toml project manifest.

Prints the required minimum version on stdout (prints nothing when the check
is disabled) and exits 0. Exits 3 with a message on stderr for anything
malformed. A requirement manifest fails closed: invalid TOML, duplicate keys
(rejected by the TOML parser), quoted or otherwise non-boolean `enabled`,
missing or non-version `minimum_version`, and unknown keys are all errors —
never a silently disabled check.

Requires Python 3.11+ for tomllib; older interpreters also fail closed, with
a message saying so.
"""

import re
import sys

VERSION_RE = re.compile(r"[0-9]+(\.[0-9]+)*")
ALLOWED_KEYS = frozenset(("enabled", "minimum_version"))


def fail(path, message):
    # type: (str, str) -> int
    print("malformed project manifest {}: {}".format(path, message), file=sys.stderr)
    return 3


def main():
    # type: () -> int
    if len(sys.argv) != 2:
        print("usage: project_manifest.py <file>", file=sys.stderr)
        return 2
    path = sys.argv[1]

    try:
        import tomllib
    except ModuleNotFoundError:
        print(
            "cannot validate project manifest {}: python3 lacks tomllib "
            "(Python >= 3.11 required); failing closed".format(path),
            file=sys.stderr,
        )
        return 3

    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except OSError as exc:
        print("cannot read project manifest {}: {}".format(path, exc), file=sys.stderr)
        return 3
    except tomllib.TOMLDecodeError as exc:
        return fail(path, "invalid TOML: {}".format(exc))

    unknown = sorted(set(data) - ALLOWED_KEYS)
    if unknown:
        return fail(path, "unknown key(s): {}".format(", ".join(unknown)))

    if "enabled" not in data:
        return fail(path, "missing required key `enabled`")
    enabled = data["enabled"]
    if not isinstance(enabled, bool):
        return fail(
            path,
            "`enabled` must be a bare TOML boolean (true or false), got: {!r}".format(enabled),
        )

    if enabled is False:
        return 0

    if "minimum_version" not in data:
        return fail(path, "missing required key `minimum_version`")
    minimum = data["minimum_version"]
    if not isinstance(minimum, str) or not VERSION_RE.fullmatch(minimum):
        return fail(
            path,
            '`minimum_version` must be a plain version string like "1.4.1", got: {!r}'.format(minimum),
        )

    print(minimum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
