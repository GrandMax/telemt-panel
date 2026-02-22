#!/usr/bin/env bash
# Build and optionally push telemt Docker image to grandmax/telemt-pannel.
# For push you must be logged in: docker login
# Usage: from repo root, run: ./scripts/build-docker-release.sh [--no-push]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${TELEMT_DOCKER_IMAGE:-grandmax/telemt-pannel}"
NO_PUSH=false

for arg in "$@"; do
	case "$arg" in
		--no-push) NO_PUSH=true ;;
		-h|--help)
			echo "Usage: $0 [--no-push]"
			echo "  Build telemt image and tag as ${IMAGE}:latest and ${IMAGE}:<version>."
			echo "  With --no-push only build locally (no docker push)."
			echo "  Run from repo root; requires docker login for push."
			exit 0
			;;
	esac
done

cd "$REPO_ROOT"
if [[ ! -f Dockerfile ]] || [[ ! -f Cargo.toml ]]; then
	echo "Run this script from the telemt repo root (Dockerfile and Cargo.toml must exist)." >&2
	exit 1
fi

VERSION=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' Cargo.toml | head -n1)
if [[ -z "$VERSION" ]]; then
	VERSION="unknown"
fi

echo "Building ${IMAGE}:latest and ${IMAGE}:${VERSION} ..."
docker build -t "${IMAGE}:latest" -t "${IMAGE}:${VERSION}" .

if [[ "$NO_PUSH" == true ]]; then
	echo "Build done (--no-push: not pushing)."
	exit 0
fi

echo "Pushing ${IMAGE}:latest and ${IMAGE}:${VERSION} ..."
docker push "${IMAGE}:latest"
docker push "${IMAGE}:${VERSION}"
echo "Done."
