#!/usr/bin/env bash

# sync-zizmor-versions.sh: fetch and store all tagged versions of
# zizmorcore/zizmor on GHCR

set -eu

CI=${CI:-false}
IMAGE="ghcr.io/zizmorcore/zizmor"

err() {
    [[ "${CI}" = "true" ]] && echo "::error::${*}" || echo "ERROR: ${*}" >&2
}

die() {
  err "${*}"
  exit 1
}

installed() {
    command -v "${1}" >/dev/null 2>&1
}

installed skopeo || die "'skopeo' is required to continue"
installed jq || die "'jq' is required to continue"

tags=$(skopeo list-tags "docker://${IMAGE}" | jq -r '.Tags[]')

# For each tag, get the corresponding image's digest with `skopeo inspect`
# and emit it as a line in the format:
# <tag> <digest>
for tag in ${tags}; do
    # Skip prerelease versions (e.g. 1.30.0rc1, 1.30.0-beta.1)
    # Only allow "latest" or strict MAJOR.MINOR.PATCH.
    if [[ "${tag}" != "latest" ]] && ! [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        continue
    fi
    # Retry up to 5 times, since GHCR is unreliable.
    digest=$(skopeo --override-os=linux --override-arch=amd64 inspect --retry-times=5 "docker://${IMAGE}:${tag}" | jq -r '.Digest')
    echo "${tag} ${digest}"
done
