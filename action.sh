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

[[ "${RUNNER_OS}" != "Linux" ]] && warn "Unsupported runner OS: ${RUNNER_OS}"

output="${RUNNER_TEMP}/zizmor"

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
[[ "${GHA_ZIZMOR_STRICT_COLLECTION}" == "true" ]] && arguments+=("--strict-collection")
[[ "${GHA_ZIZMOR_ONLINE_AUDITS}" == "true" ]] || arguments+=("--no-online-audits")
[[ -n "${GHA_ZIZMOR_MIN_SEVERITY}" ]] && arguments+=("--min-severity=${GHA_ZIZMOR_MIN_SEVERITY}")
[[ -n "${GHA_ZIZMOR_MIN_CONFIDENCE}" ]] && arguments+=("--min-confidence=${GHA_ZIZMOR_MIN_CONFIDENCE}")
[[ "${GHA_ZIZMOR_COLOR}" == "true" ]] && arguments+=("--color=always") || arguments+=("--color=never")

if [[ -n "${GHA_ZIZMOR_CONFIG:-}" ]]; then
    arguments+=("--config=${GHA_ZIZMOR_CONFIG}")
fi

version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+((a|b|rc)[0-9]+)?(\.dev[0-9]+)?$'

locks="${GITHUB_ACTION_PATH}/support/locks"
case "${GHA_ZIZMOR_VERSION}" in
    # Read the appropriate latest or prerelease version from its respective file.
    latest|prerelease|"")
        read -r zizmor_version < "${locks}/${GHA_ZIZMOR_VERSION:-latest}"
        ;;
    *)
        [[ "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
            || die "'version' must be 'latest', 'prerelease', or an exact X.Y.Z version (optionally with a prerelease suffix)"
        zizmor_version="${GHA_ZIZMOR_VERSION#v}"
        ;;
esac

manifest="${locks}/zizmor-${zizmor_version}.tsv"
[[ -f "${manifest}" ]] || die "Unknown version ${zizmor_version}; was it released after this action?"

target="${RUNNER_OS}-${RUNNER_ARCH}"
exe=zizmor
[[ ${RUNNER_OS} == Windows ]] && exe=zizmor.exe

while IFS=$'\t' read -r platform sha256 url; do
    [[ ${platform} == "${target}" ]] && break
done < "${manifest}"
[[ ${platform:-} == "${target}" ]] || die "No zizmor ${zizmor_version} wheel for ${target}"

for tool in curl unzip; do
    installed "${tool}" || die "Missing required tool: ${tool}"
done
if installed sha256sum; then
    checksum=(sha256sum -b)
elif installed shasum; then
    checksum=(shasum -a 256 -b)
else
    die "Missing required tool: sha256sum or shasum"
fi

wheeldir=$(mktemp -d "${RUNNER_TEMP}/zizmor-wheel.XXXXXXXX")
trap 'rm -rf "${wheeldir}"' EXIT
wheel="${wheeldir}/zizmor.whl"
curl --disable --proto '=https' --tlsv1.2 --location \
    --fail --silent --show-error --retry 3 --output "${wheel}" "${url}"
actual=$("${checksum[@]}" < "${wheel}")
[[ ${actual%% *} == "${sha256}" ]] || die "SHA-256 mismatch for zizmor ${zizmor_version} on ${target}"

zizmor="${wheeldir}/${exe}"
unzip -p "${wheel}" "zizmor-${zizmor_version}.data/scripts/${exe}" > "${zizmor}"
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
