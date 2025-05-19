#!/usr/bin/env -S uv run --no-project --script

# action.py: bootstrap and run `zizmor` as specified in `action.yml`.


import os
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


def _input[T](name: str, parser: abc.Callable[[str], T]) -> T:
    """Get input from the user."""
    envname = f"GHA_ZIZMOR_{name.replace('-', '_').upper()}"
    raw = os.getenv(envname)
    if raw is None:
        _die(f"Missing required environment variable {envname}")

    try:
        return parser(raw)
    except ValueError as exc:
        _die(f"couldn't parse input {name}: {exc}")


def _tmpfile() -> Path:
    runner_temp = os.getenv("RUNNER_TEMP")
    if runner_temp is None:
        _die("RUNNER_TEMP not set")
    tmpfile = tempfile.NamedTemporaryFile(
        delete=False, delete_on_close=False, dir=runner_temp
    )
    return Path(tmpfile.name)


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

    # Don't allow flag-like inputs. These won't have an affect anyways
    # since we delimit with `--`, but we preempt any user temptation to try.
    for input in inputs:
        if input.startswith("-"):
            _die(f"Invalid input: {input} looks like a flag")

    _debug(f"{inputs=} {version=} {advanced_security=}")

    uvx = shutil.which("uvx")
    if uvx is None:
        _die("uvx not found in PATH")

    _debug(f"uvx: {uvx}")

    # uvx uses `tool@version`, where `version` can be a version or "latest"
    spec = f"zizmor@{version}"

    args = [uvx, spec, "--color=always"]
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
        sarif = _tmpfile()
        sarif.write_bytes(result.stdout)
        _output("sarif-file", str(sarif))
    else:
        sys.stdout.buffer.write(result.stdout)

    if result.returncode != 0:
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
