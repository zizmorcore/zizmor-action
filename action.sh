#!/usr/bin/env bash

# action.sh: run zizmor via uv

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

installed uv || die "Cannot run this action without uv"

[[ "${RUNNER_OS}" != "Linux" ]] && warn "Unsupported runner OS: ${RUNNER_OS}"

output="${RUNNER_TEMP}/zizmor"

version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+$'

case "${GHA_ZIZMOR_VERSION}" in
    locked|"") resolution="locked" ;;
    latest) resolution="latest" ;;
    *)
        [[ "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
            || die "'version' must be 'locked', 'latest' or an exact X.Y.Z version"
        resolution="pinned"
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

normalized_version="${GHA_ZIZMOR_VERSION#v}"

zizmor_command=()
case "${resolution}" in
    locked)
        # The default version is the one pinned in this action's uv.lock,
        # which Dependabot keeps current. `--locked` refuses to re-resolve
        # if the lockfile and pyproject.toml have drifted apart, and the
        # lock records a hash for every wheel, so this is verified as well
        # as pinned.
        #
        # The environment goes under RUNNER_TEMP rather than into the
        # action's own checkout.
        export UV_PROJECT_ENVIRONMENT="${RUNNER_TEMP}/zizmor-env"
        zizmor_command=(uv run --project "${GITHUB_ACTION_PATH}" --locked zizmor)
        ;;
    latest)
        zizmor_command=(uvx "zizmor@latest")
        ;;
    pinned)
        zizmor_command=(uvx "zizmor@${normalized_version}")
        ;;
esac

# Notes:
# - uv resolves the right wheel for the runner's architecture itself, and
#   an unknown version fails here as a resolution error.
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
