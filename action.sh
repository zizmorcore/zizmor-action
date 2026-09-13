#!/usr/bin/env bash

# action.sh: run zizmor from a hash-verified wheel

set -eu

dbg() {
    echo "::debug::${*}"
}

warn() {
    echo "::warning::${*}"
}

err() {
    echo "::error::${*}"
}

die() {
  err "${*}"
  exit 1
}

installed() {
    command -v "${1}" >/dev/null 2>&1
}

output() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

installed python3 || die "Cannot run this action without Python"

[[ "${RUNNER_OS}" != "Linux" ]] && warn "Unsupported runner OS: ${RUNNER_OS}"

output="${RUNNER_TEMP}/zizmor"

version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+$'

# `latest` means the newest zizmor release this action knows about, i.e. the
# one recorded in `support/zizmor-version` by the version-sync workflow. It
# resolves out of the action's own tree rather than from PyPI, so a given
# release of this action always runs the same zizmor release.
case "${GHA_ZIZMOR_VERSION}" in
    latest|"")
        zizmor_version="$(< "${GITHUB_ACTION_PATH}/support/zizmor-version")"
        ;;
    *)
        [[ "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
            || die "'version' must be 'latest' or an exact X.Y.Z version"
        zizmor_version="${GHA_ZIZMOR_VERSION#v}"
        ;;
esac

arguments=()
arguments+=("--persona=${GHA_ZIZMOR_PERSONA}")

if [[ "${GHA_ZIZMOR_ADVANCED_SECURITY}" == "true" && "${GHA_ZIZMOR_ANNOTATIONS}" == "true" ]]; then
    err "Mutually exclusive options: 'advanced-security: true' and 'annotations: true'"
    die "If you meant to enable 'annotations: true', you must explicitly set 'advanced-security: false'"
fi

if [[ "${GHA_ZIZMOR_ADVANCED_SECURITY}" == "true" ]]; then
    arguments+=("--format=sarif")
    output "sarif-file" "${output}"
elif [[ "${GHA_ZIZMOR_ANNOTATIONS}" == "true" ]]; then
    arguments+=("--format=github")
fi

[[ -n "${GHA_ZIZMOR_COLLECT}" ]] && arguments+=("--collect=${GHA_ZIZMOR_COLLECT}")
[[ "${GHA_ZIZMOR_ONLINE_AUDITS}" == "true" ]] || arguments+=("--no-online-audits")
[[ -n "${GHA_ZIZMOR_MIN_SEVERITY}" ]] && arguments+=("--min-severity=${GHA_ZIZMOR_MIN_SEVERITY}")
[[ -n "${GHA_ZIZMOR_MIN_CONFIDENCE}" ]] && arguments+=("--min-confidence=${GHA_ZIZMOR_MIN_CONFIDENCE}")
[[ "${GHA_ZIZMOR_COLOR}" == "true" ]] && arguments+=("--color=always") || arguments+=("--color=never")

if [[ -n "${GHA_ZIZMOR_CONFIG:-}" ]]; then
    arguments+=("--config=${GHA_ZIZMOR_CONFIG}")
fi

lockfile="${GITHUB_ACTION_PATH}/support/locks/zizmor-${zizmor_version}.txt"
[[ -f "${lockfile}" ]] \
    || die "Unknown version ${zizmor_version}; was it released after this action?"

# The lock pins every wheel for this version by hash, so `--require-hashes`
# gives us the same guarantee the pinned container digests used to: pip picks
# the wheel matching the runner and verifies it against that set.
wheeldir="${RUNNER_TEMP}/zizmor-wheel"
rm -rf "${wheeldir}"
mkdir -p "${wheeldir}"

python3 -m pip download \
    --quiet --no-input --disable-pip-version-check \
    --only-binary=:all: \
    --no-deps \
    --require-hashes \
    --dest "${wheeldir}" \
    --requirement "${lockfile}"

wheels=("${wheeldir}"/*.whl)
[[ -f "${wheels[0]}" ]] || die "No zizmor ${zizmor_version} wheel for this runner"

# Wheels are just ZIPs, and zizmor's contains nothing but its executable, so
# unpacking one is the whole installation: no environment to create or remove.
python3 -m zipfile --extract "${wheels[0]}" "${wheeldir}/unpacked"

zizmor="${wheeldir}/unpacked/zizmor-${zizmor_version}.data/scripts/zizmor"
[[ -f "${zizmor}" ]] || zizmor="${zizmor}.exe"
[[ -f "${zizmor}" ]] || die "Wheel for zizmor ${zizmor_version} contains no executable"

# ZIPs carry no permission bits that `zipfile` restores.
chmod +x "${zizmor}"

# Notes:
# - We run from ${GITHUB_WORKSPACE}, so that user inputs like '.' resolve
#   correctly.
# - We pass the GitHub token as an environment variable so that zizmor
#   can run online audits/perform online collection if requested.
# - ${GHA_ZIZMOR_INPUTS} is intentionally not quoted, so that
#   it can expand according to the shell's word-splitting rules.
#   However, we put it after `--` so that it can't be interpreted
#   as one or more flags.
cd "${GITHUB_WORKSPACE}"

# shellcheck disable=SC2086
GH_TOKEN="${GHA_ZIZMOR_TOKEN}" "${zizmor}" \
    "${arguments[@]}" \
    -- \
    ${GHA_ZIZMOR_INPUTS} \
        | tee "${output}"

exitcode="${PIPESTATUS[0]}"
dbg "zizmor exited with code ${exitcode}"

if [[ "${exitcode}" -eq 3 ]]; then
    warn "No inputs were collected by zizmor"
    [[ "${GHA_ZIZMOR_FAIL_ON_NO_INPUTS}" = "false" ]] && exit 0
fi

exit "${exitcode}"
