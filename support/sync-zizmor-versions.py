#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["packaging"]
# ///

"""Add stable zizmor releases to uv dependency groups, compile hash-pinned
requirements, and update the default zizmor version."""

import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, NoReturn

from packaging.version import Version

PACKAGE = "zizmor"
PYPI_JSON = f"https://pypi.org/pypi/{PACKAGE}/json"
RETRIES = 5

HERE = Path(__file__).resolve().parent
LOCKS = HERE / "locks"

CI = os.environ.get("CI") == "true"


def die(message: str) -> NoReturn:
    print(f"::error::{message}" if CI else f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def releases() -> dict[str, list[dict[str, Any]]]:
    """The PyPI release index for `PACKAGE`. PyPI is occasionally flaky, so
    this retries a few times before giving up."""
    for attempt in range(1, RETRIES + 1):
        try:
            with urllib.request.urlopen(PYPI_JSON, timeout=30) as response:
                return json.load(response)["releases"]
        except (OSError, ValueError, KeyError) as exc:
            if attempt == RETRIES:
                die(f"Could not fetch {PYPI_JSON}: {exc}")
            time.sleep(attempt)

    raise AssertionError("unreachable")


def uv(*args: str) -> None:
    subprocess.run(
        ["uv", "--quiet", "--no-python-downloads", *args],
        cwd=HERE,
        check=True,
    )


def main() -> None:
    versions = sorted(
        (
            version
            for version, files in releases().items()
            if not Version(version).is_prerelease
            and any(f["packagetype"] == "bdist_wheel" and not f["yanked"] for f in files)
        ),
        key=Version,
    )
    if not versions:
        die(f"Found no stable release of {PACKAGE!r} on PyPI")

    groups = {f"{PACKAGE}-{version}": version for version in versions}
    groups[f"{PACKAGE}-latest"] = versions[-1]
    LOCKS.mkdir(exist_ok=True)
    for group, version in groups.items():
        # The groups are independent: never resolve all versions together.
        uv("add", "--frozen", "--group", group, f"{PACKAGE}=={version}")
        uv(
            "pip", "compile",
            "--group", group,
            "--universal", "--python-version", "3.10",
            "--generate-hashes", "--no-build",
            "--no-header", "--no-annotate",
            "--output-file", str(LOCKS / f"{group}.txt"),
        )

    print(f"Default version: {versions[-1]}", file=sys.stderr)


if __name__ == "__main__":
    main()
