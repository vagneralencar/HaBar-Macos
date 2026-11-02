#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE_INPUT="${1:-}"
RELEASE_VERSION="${RELEASE_INPUT#v}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 <major.minor.patch>" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash changes before preparing a release." >&2; exit 1; }
swift test
printf '%s\n' "$RELEASE_VERSION" > VERSION
git add VERSION
git diff --cached --quiet || git commit -m "chore(release): bump version to $RELEASE_VERSION"
git tag -a "v$RELEASE_VERSION" -m "HaBar $RELEASE_VERSION"
echo "Prepared v$RELEASE_VERSION. Push the commit and tag when ready. CI alone builds and publishes the signed archive."
