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
    digest=$(skopeo --override-os=linux --override-arch=amd64  inspect "docker://${IMAGE}:${tag}" | jq -r '.Digest')
    echo "${tag} ${digest}"
done
