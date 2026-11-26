#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["packaging"]
# ///

"""Pin the wheel URL and digest for each release and runner platform."""

import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, NoReturn

from packaging.utils import parse_wheel_filename
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


def wheel_target(platform: str) -> str | None:
    # zizmor's musllinux wheels contain static executables that also run on glibc.
    if match := re.fullmatch(r"(musllinux|macosx)_\d+_\d+_(\w+)", platform):
        family, arch = match.groups()
        os_name = "Linux" if family == "musllinux" else "macOS"
        runner_arch = {
            "x86_64": "X64",
            "i686": "X86",
            "armv7l": "ARM",
            "aarch64": "ARM64",
            "arm64": "ARM64",
        }[arch]
        return f"{os_name}-{runner_arch}"

    if platform.startswith("manylinux"):
        return None

    return {
        "win32": "Windows-X86",
        "win_amd64": "Windows-X64",
        "win_arm64": "Windows-ARM64",
    }[platform]


def manifest(files: list[dict[str, Any]]) -> str:
    rows = {}
    for file in files:
        if file["packagetype"] != "bdist_wheel" or file["yanked"]:
            continue
        filename = file["filename"]
        _, _, _, tags = parse_wheel_filename(filename)
        for tag in tags:
            if (tag.interpreter, tag.abi) != ("py3", "none"):
                die(f"Unexpected wheel tag {tag} in {filename}")
            try:
                target = wheel_target(tag.platform)
            except KeyError:
                die(f"Unexpected wheel platform {tag.platform} in {filename}")
            if target is None:
                continue
            row = (target, file["digests"]["sha256"], file["url"])
            if rows.setdefault(target, row) != row:
                die(f"Conflicting wheels for {target}: {filename} and {rows[target][-1]}")

    return "".join("\t".join(rows[target]) + "\n" for target in sorted(rows))


def main() -> None:
    manifests = {}
    for version, files in releases().items():
        if data := manifest(files):
            manifests[version] = data
    versions = sorted(manifests, key=Version)
    stable_versions = [version for version in versions if not Version(version).is_prerelease]
    prerelease_versions = [version for version in versions if Version(version).is_prerelease]
    if not stable_versions:
        die(f"Found no stable release of {PACKAGE!r} on PyPI")
    if not prerelease_versions:
        die(f"Found no prerelease of {PACKAGE!r} on PyPI")

    LOCKS.mkdir(exist_ok=True)
    for version, data in manifests.items():
        (LOCKS / f"{PACKAGE}-{version}.tsv").write_text(data)
    (LOCKS / "latest").write_text(stable_versions[-1] + "\n")
    (LOCKS / "prerelease").write_text(prerelease_versions[-1] + "\n")

    print(f"Default version: {stable_versions[-1]}", file=sys.stderr)
    print(f"Prerelease version: {prerelease_versions[-1]}", file=sys.stderr)


if __name__ == "__main__":
    main()
