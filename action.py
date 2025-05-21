#!/usr/bin/env python

# action.py: bootstrap and run `zizmor` as specified in `action.yml`.

from __future__ import annotations

import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import typing
from collections import abc
from pathlib import Path


def _die(msg: str) -> typing.NoReturn:
    print(f"::error::{msg}", file=sys.stdout)
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def _debug(msg: str):
    print(f"::debug::{msg}", file=sys.stdout)


def _tmpdir() -> Path:
    runner_temp = os.getenv("RUNNER_TEMP")
    if runner_temp is None:
        _die("RUNNER_TEMP not set")
    tmpdir = tempfile.mkdtemp(prefix="zizmor-", dir=runner_temp)
    return Path(tmpdir)


def _tmpfile(name: str) -> Path:
    return _tmpdir() / name


def _triple() -> str:
    uname = platform.uname()
    if uname.system == "Darwin":
        if uname.machine == "arm64":
            return "aarch64-apple-darwin"
        elif uname.machine == "x86_64":
            return "x86_64-apple-darwin"
    elif uname.system == "Linux":
        if uname.machine == "x86_64":
            return "x86_64-unknown-linux-gnu"
        elif uname.machine == "aarch64":
            return "aarch64-unknown-linux-gnu"

    # TODO: Windows

    _die(f"unsupported platform: {uname.system} {uname.machine}")


def _download(triple: str, version: str, token: str) -> Path:
    tmpdir = _tmpdir()

    download_args = [
        "gh",
        "release",
        "download",
        "--repo",
        "zizmorcore/zizmor",
        "--pattern",
        f"zizmor-{triple}*",
        "--dir",
        str(tmpdir),
    ]

    if version != "latest":
        download_args.append(version)

    _debug(f"downloading: {download_args}")

    result = subprocess.run(
        download_args,
        capture_output=True,
        env={
            "GH_TOKEN": token,
        },
    )
    if result.returncode != 0:
        _debug(f"download failed: {result.stderr.decode()}")
        _die(f"failed to download zizmor ({triple=} {version=})")

    files = list(tmpdir.iterdir())
    if len(files) != 1:
        _die(f"expected exactly one file in {tmpdir}, got {len(files)}")

    return files[0]


def _verify(archive: Path, token: str):
    verify_args = [
        "gh",
        "attestation",
        "verify",
        "--repo",
        "zizmorcore/zizmor",
        str(archive),
    ]

    _debug(f"verifying: {verify_args}")

    result = subprocess.run(
        verify_args,
        capture_output=True,
        env={
            "GH_TOKEN": token,
        },
    )

    if result.returncode != 0:
        _debug(f"verification failed: {result.stderr.decode()}")
        _die(f"failed to verify {archive}")


def _unpack(archive: Path) -> Path:
    tmpdir = _tmpdir()
    shutil.unpack_archive(archive, tmpdir)

    zizmor = tmpdir / "zizmor"
    if not zizmor.is_file():
        _die(f"no zizmor binary found in {archive}")

    return zizmor


def _bootstrap(version: str, token: str) -> Path:
    triple = _triple()
    archive = _download(triple, version, token)

    _verify(archive, token)

    return _unpack(archive)


_T = typing.TypeVar("_T")


def _input(name: str, parser: abc.Callable[[str], _T]) -> _T:
    """Get input from the user."""
    envname = f"GHA_ZIZMOR_{name.replace('-', '_').upper()}"
    raw = os.getenv(envname)
    if raw is None:
        _die(f"Missing required environment variable {envname}")

    try:
        return parser(raw)
    except ValueError as exc:
        _die(f"couldn't parse input {name}: {exc}")


def _output(name: str, value: str):
    output = os.getenv("GITHUB_OUTPUT")
    if output is None:
        _die("GITHUB_OUTPUT not set")

    with open(output, "a") as f:
        print(f"{name}={value}", file=f)


def _strtobool(v: str) -> bool:
    v = v.lower()
    match v:
        case "true" | "1" | "yes":
            return True
        case "false" | "0" | "no":
            return False
        case _:
            raise ValueError(f"invalid boolean value: {v}")


def _persona(v: str) -> str:
    if v not in {"regular", "pedantic", "auditor"}:
        raise ValueError(f"invalid persona: {v}")
    return v


def _min_severity(v: str) -> str | None:
    if not v:
        return None

    if v not in {"unknown", "informational", "low", "medium", "high"}:
        raise ValueError(f"invalid minimum severity: {v}")
    return v


def _min_confidence(v: str) -> str | None:
    if not v:
        return None

    if v not in {"unknown", "low", "medium", "high"}:
        raise ValueError(f"invalid minimum confidence: {v}")
    return v


def main():
    inputs = _input("inputs", shlex.split)
    online_audits = _input("online-audits", _strtobool)
    persona = _input("persona", _persona)
    min_severity = _input("min-severity", _min_severity)
    min_confidence = _input("min-confidence", _min_confidence)
    version = _input("version", str)
    token = _input("token", str)
    advanced_security = _input("advanced-security", _strtobool)

    zizmor = _bootstrap(version, token)

    # Don't allow flag-like inputs. These won't have an affect anyways
    # since we delimit with `--`, but we preempt any user temptation to try.
    for input in inputs:
        if input.startswith("-"):
            _die(f"Invalid input: {input} looks like a flag")

    _debug(f"{inputs=} {version=} {advanced_security=}")

    args = [str(zizmor), "--color=always"]
    if advanced_security:
        args.append("--format=sarif")
    else:
        args.append("--format=plain")

    if not online_audits:
        args.append("--no-online-audits")

    args.append(f"--persona={persona}")

    if min_severity:
        args.append(f"--min-severity={min_severity}")

    if min_confidence:
        args.append(f"--min-confidence={min_confidence}")

    args.append("--")
    args.extend(inputs)

    _debug(f"running: {args}")

    result = subprocess.run(
        args,
        env={
            "GH_TOKEN": token,
        },
        stdout=subprocess.PIPE,
        stderr=None,
    )

    if advanced_security:
        sarif = _tmpfile("sarif.json")
        sarif.write_bytes(result.stdout)
        _output("sarif-file", str(sarif))
    else:
        sys.stdout.buffer.write(result.stdout)

    if result.returncode != 0:
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
