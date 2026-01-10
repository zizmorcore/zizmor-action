#!/usr/bin/env bash

# action.sh: run zizmor via Docker

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

installed docker || die "Cannot run this action without Docker"

[[ "${RUNNER_OS}" != "Linux" ]] && warn "Unsupported runner OS: ${RUNNER_OS}"

# Load an associative array of versions from `./support/versions`.
# Each line is of the form `version digest`.
declare -A versions
parent_dir=$(dirname "${GITHUB_ACTION_PATH}")
while IFS=' ' read -r version digest; do
    versions["${version}"]="${digest}"
done < "${parent_dir}/support/versions"

output="${RUNNER_TEMP}/zizmor"

version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+$'

[[ "${GHA_ZIZMOR_VERSION}" == "latest" || "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
    || die "'version' must be 'latest' or an exact X.Y.Z version"

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

[[ "${GHA_ZIZMOR_ONLINE_AUDITS}" == "true" ]] || arguments+=("--no-online-audits")
[[ -n "${GHA_ZIZMOR_MIN_SEVERITY}" ]] && arguments+=("--min-severity=${GHA_ZIZMOR_MIN_SEVERITY}")
[[ -n "${GHA_ZIZMOR_MIN_CONFIDENCE}" ]] && arguments+=("--min-confidence=${GHA_ZIZMOR_MIN_CONFIDENCE}")
[[ "${GHA_ZIZMOR_COLOR}" == "true" ]] && arguments+=("--color=always") || arguments+=("--color=never")

if [[ -n "${GHA_ZIZMOR_CONFIG:-}" ]]; then
    arguments+=("--config=${GHA_ZIZMOR_CONFIG}")
fi

normalized_version="${GHA_ZIZMOR_VERSION#v}"
digest="${versions[${normalized_version}]:-}"

# We only proceed if we have a digest for the requested version; a lookup
# failure indicates an unknown version (i.e. either nonsense or a version
# that was released after this action's last release).
if [[ -z "${digest}" ]]; then
    die "Unknown version: ${GHA_ZIZMOR_VERSION}"
fi

image="ghcr.io/zizmorcore/zizmor:${normalized_version}@${digest}"

# Notes:
# - We run the container with ${GITHUB_WORKSPACE} mounted as /workspace
#   and with /workspace as the working directory, so that user inputs
#   like '.' resolve correctly.
# - We pass the GitHub token as an environment variable so that zizmor
#   can run online audits/perform online collection if requested.
# - ${GHA_ZIZMOR_INPUTS} is intentionally not quoted, so that
#   it can expand according to the shell's word-splitting rules.
#   However, we put it after `--` so that it can't be interpreted
#   as one or more flags.
#
# shellcheck disable=SC2086
docker run \
    --rm \
    --volume "${GITHUB_WORKSPACE}:/workspace:ro" \
    --workdir "/workspace" \
    --env "GH_TOKEN=${GHA_ZIZMOR_TOKEN}" \
    "${image}" \
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
