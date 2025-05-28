#!/usr/bin/env bash

# action.sh: run zizmor via Docker

set -euo pipefail

dbg() {
    echo "::debug::${*}"
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

run() {
    dbg "${@}"
    "${@}"
}

installed docker || die "missing \`docker\` command"

version_regex='^[0-9]+\.[0-9]+\.[0-9]+$'

[[ "${GHA_ZIZMOR_VERSION}" == "latest" || "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
    || die "'version' must be 'latest' or an exact X.Y.Z version"

arguments=()
arguments+=("--persona=${GHA_ZIZMOR_PERSONA}")

[[ "${GHA_ZIZMOR_ADVANCED_SECURITY}" == true ]] && arguments+=("--format=sarif")
[[ "${GHA_ZIZMOR_ONLINE_AUDITS}" == "true" ]] || arguments+=("--no-online-audits")
[[ -n "${GHA_ZIZMOR_MIN_SEVERITY}" ]] && arguments+=("--min-severity=${GHA_ZIZMOR_MIN_SEVERITY}")
[[ -n "${GHA_ZIZMOR_MIN_CONFIDENCE}" ]] && arguments+=("--min-confidence=${GHA_ZIZMOR_MIN_CONFIDENCE}")

image="ghcr.io/zizmorcore/zizmor:${GHA_ZIZMOR_VERSION}"

output="${RUNNER_TEMP}/zizmor"

# Notes:
# - We run the container with ${GITHUB_WORKSPACE} mounted as /workspace
#   and with /workspace as the working directory, so that user inputs
#   like '.' resolve correctly.
# - We pass the GitHub token as an environment variable so that zizmor
#   can run online audits/perform online collection if requested.
# - We pass FORCE_COLOR=1 so that the output is always colored, even
#   though we intentionally don't `docker run -it`.
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
    --env "FORCE_COLOR=1" \
    "${image}" \
    "${arguments[@]}" \
    -- \
    ${GHA_ZIZMOR_INPUTS} \
        | tee "${output}"
