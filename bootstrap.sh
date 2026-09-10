#!/usr/bin/env bash

# bootstrap.sh: decide how `action.sh` should run zizmor

set -eu

warn() {
    echo "::warning::${*}"
}

installed() {
    command -v "${1}" >/dev/null 2>&1
}

output() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

# Docker is preferred: the image is content-addressable, so `action.sh` can
# check it against a known digest, and it handles multi-arch selection for us.
#
# Checking for the client alone isn't enough: `ubuntu-slim` ships the Docker
# client without a daemon, so `docker pull` there fails with a connection
# error rather than a missing-command error.
if installed docker && docker info >/dev/null 2>&1; then
    output "method" "docker"
else
    warn "No usable Docker daemon; falling back to uv to bootstrap zizmor"
    output "method" "uv"
fi
