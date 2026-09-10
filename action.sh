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

# The default version is the one recorded in `support/zizmor-version`, which
# the version-sync workflow keeps current; each release of this action
# therefore pins the zizmor release that was current when it was cut.
#
# `latest` is deliberately unsupported: resolving it at run time would make
# the version of zizmor a workflow runs mutable, which is what pinning is
# meant to prevent.
case "${GHA_ZIZMOR_VERSION}" in
    pinned|"")
        zizmor_version="$(< "${GITHUB_ACTION_PATH}/support/zizmor-version")"
        ;;
    latest)
        err "'version: latest' is no longer supported, because it cannot be pinned"
        die "Use 'pinned' (the default) or an exact X.Y.Z version instead"
        ;;
    *)
        [[ "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
            || die "'version' must be 'pinned' or an exact X.Y.Z version"
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
    || die "No lock for zizmor ${zizmor_version}; it is either nonsense or newer than this action's last release"

# The lock pins every wheel for this version by hash, so `--require-hashes`
# gives us the same guarantee the pinned container digests used to. pip picks
# the wheel matching the runner and verifies it against that set.
venv="${RUNNER_TEMP}/zizmor-venv"
bindir="${RUNNER_TEMP}/zizmor-bin"
rm -rf "${venv}" "${bindir}"

python3 -m venv "${venv}"
"${venv}/bin/python" -m pip install \
    --quiet --no-input --disable-pip-version-check \
    --only-binary=:all: \
    --require-hashes \
    --requirement "${lockfile}"

# zizmor's wheels ship a self-contained native executable, so the virtual
# environment is only a means of getting a verified copy of it onto the
# runner. Keep the binary, drop everything else.
mkdir -p "${bindir}"
cp "${venv}/bin/zizmor" "${bindir}/zizmor"
rm -rf "${venv}"

"${bindir}/zizmor" --version >/dev/null 2>&1 \
    || die "zizmor is not self-contained on this runner and cannot run outside its virtual environment"

zizmor_command=("${bindir}/zizmor")

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
GH_TOKEN="${GHA_ZIZMOR_TOKEN}" "${zizmor_command[@]}" \
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
