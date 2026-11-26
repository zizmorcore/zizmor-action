#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["packaging"]
# ///

"""Pin the wheel URL and digest for each release and runner platform."""

import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import NamedTuple, NewType, NoReturn, TypedDict

from packaging.utils import parse_wheel_filename
from packaging.version import Version

PACKAGE = "zizmor"
PYPI_JSON = f"https://pypi.org/pypi/{PACKAGE}/json"
RETRIES = 5

RunnerTarget = NewType("RunnerTarget", str)
"""Key from RUNNER_OS and RUNNER_ARCH, e.g. Linux-X64."""


class ReleaseFile(TypedDict):
    """Metadata from a single distribution."""

    filename: str
    packagetype: str
    yanked: bool
    digests: dict[str, str]
    url: str


class WheelPin(NamedTuple):
    sha256: str
    url: str


WHEEL_TARGETS: dict[str, RunnerTarget] = {
    # zizmor's musllinux wheels contain static executables that also run on glibc.
    "musllinux_1_2_aarch64": RunnerTarget("Linux-ARM64"),
    "musllinux_1_2_armv7l": RunnerTarget("Linux-ARM"),
    "musllinux_1_2_i686": RunnerTarget("Linux-X86"),
    "musllinux_1_2_x86_64": RunnerTarget("Linux-X64"),
    "macosx_11_0_arm64": RunnerTarget("macOS-ARM64"),
    "macosx_10_12_x86_64": RunnerTarget("macOS-X64"),
    "win_arm64": RunnerTarget("Windows-ARM64"),
    "win_amd64": RunnerTarget("Windows-X64"),
    "win32": RunnerTarget("Windows-X86"),
}

HERE = Path(__file__).resolve().parent
LOCKS = HERE / "locks"

CI = os.environ.get("CI") == "true"


def die(message: str) -> NoReturn:
    print(f"::error::{message}" if CI else f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def releases() -> dict[str, list[ReleaseFile]]:
    """Fetch zizmor's distributions, keyed by their version."""
    for attempt in range(1, RETRIES + 1):
        try:
            with urllib.request.urlopen(PYPI_JSON, timeout=30) as response:
                return json.load(response)["releases"]
        except (OSError, ValueError, KeyError) as exc:
            if attempt == RETRIES:
                die(f"Could not fetch {PYPI_JSON}: {exc}")
            time.sleep(attempt)

    raise AssertionError("unreachable")


def wheel_target(filename: str) -> RunnerTarget | None:
    """Return the runner target, or None for a wheel with only manylinux tags.

    Unexpected tags or tags mapping to different runners cause sync to fail.
    """
    _, _, _, tags = parse_wheel_filename(filename)
    target = None
    for tag in tags:
        if (tag.interpreter, tag.abi) != ("py3", "none"):
            die(f"Unexpected wheel tag {tag} in {filename}")
        if tag.platform.startswith("manylinux"):
            continue
        runner = WHEEL_TARGETS.get(tag.platform)
        if runner is None:
            die(f"Unexpected wheel platform {tag.platform} in {filename}")
        if target is not None and runner != target:
            die(f"Wheel {filename} maps to multiple runners: {target} and {runner}")
        target = runner
    return target


def manifest(files: list[ReleaseFile]) -> str:
    """Turn a list of files in a zizmor release into a TSV manifest."""
    pins: dict[RunnerTarget, WheelPin] = {}
    for file in files:
        if file["packagetype"] != "bdist_wheel" or file["yanked"]:
            continue
        filename = file["filename"]
        target = wheel_target(filename)
        if target is None:
            continue
        pin = WheelPin(sha256=file["digests"]["sha256"], url=file["url"])
        if target in pins and pins[target] != pin:
            die(f"Conflicting wheels for {target}: {filename} and {pins[target].url}")
        pins[target] = pin

    return "".join(
        f"{target}\t{pin.sha256}\t{pin.url}\n" for target, pin in sorted(pins.items())
    )


def main() -> None:
    release_files = releases()
    manifests = {}
    latest_stable = latest_prerelease = None

    for version in sorted(release_files, key=Version):
        data = manifest(release_files[version])
        if not data:
            continue
        manifests[version] = data
        if Version(version).is_prerelease:
            latest_prerelease = version
        else:
            latest_stable = version

    if latest_stable is None:
        die(f"Found no stable release of {PACKAGE!r} on PyPI")
    if latest_prerelease is None:
        die(f"Found no prerelease of {PACKAGE!r} on PyPI")

    LOCKS.mkdir(exist_ok=True)
    for version, data in manifests.items():
        (LOCKS / f"{PACKAGE}-{version}.tsv").write_text(data)
    (LOCKS / "latest").write_text(latest_stable + "\n")
    (LOCKS / "prerelease").write_text(latest_prerelease + "\n")

    print(f"Default version: {latest_stable}", file=sys.stderr)
    print(f"Prerelease version: {latest_prerelease}", file=sys.stderr)


if __name__ == "__main__":
    main()
