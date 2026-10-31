#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# HaBar - Automated Release Script
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 1.6.0
# -----------------------------------------------------------------------------

if [ -z "${1:-}" ]; then
  echo "❌ Error: Version argument missing."
  echo "Usage: ./scripts/release.sh <version>"
  echo "Example: ./scripts/release.sh 1.6.0"
  exit 1
fi

VERSION="${1#v}"
TAG="v${VERSION}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_DIR"

echo "🚀 Preparing HaBar release ${TAG}..."

# 1. Run unit tests
echo "🧪 Running unit tests..."
swift test

# 2. Update version in build_app.sh
sed -i '' "s/VERSION=\"[0-9]*\.[0-9]*\.[0-9]*\"/VERSION=\"${VERSION}\"/" scripts/build_app.sh

# 3. Build .app bundle
echo "🔨 Building app bundle..."
./scripts/build_app.sh

# 4. Generate HaBar.zip
echo "📦 Packaging HaBar.zip..."
rm -f HaBar.zip HaBar.zip.sha256
ditto -c -k --keepParent HaBar.app HaBar.zip

# 5. Compute SHA256 checksum
SHA256=$(shasum -a 256 HaBar.zip | awk '{print $1}')
echo "🔑 SHA256: ${SHA256}"
echo "${SHA256}  HaBar.zip" > HaBar.zip.sha256

# 6. Update Homebrew Cask formula
if [ -f "Casks/habar.rb" ]; then
  sed -i '' "s/version \"[0-9]*\.[0-9]*\.[0-9]*\"/version \"${VERSION}\"/" Casks/habar.rb
  sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" Casks/habar.rb
  echo "🍺 Updated Casks/habar.rb with version ${VERSION} and sha256 ${SHA256}"
fi

# 7. Commit & Tag
git add scripts/build_app.sh Casks/habar.rb
if git diff --cached --quiet; then
  echo "ℹ️ No version file changes to commit."
else
  git commit -m "chore(release): bump version to ${VERSION}"
fi

echo "🏷️ Creating git tag ${TAG}..."
git tag -a "${TAG}" -m "HaBar ${TAG}"

echo "⬆️ Pushing commit and tag to origin..."
git push origin main
git push origin "${TAG}"

# 8. Create GitHub Release via gh CLI if installed
if command -v gh &> /dev/null; then
  echo "🌐 Creating GitHub Release via gh CLI..."
  gh release create "${TAG}" HaBar.zip HaBar.zip.sha256 \
    --title "HaBar ${TAG}" \
    --generate-notes
  echo "✅ GitHub Release created: https://github.com/vagneralencar/HaBar-Macos/releases/tag/${TAG}"
else
  echo "ℹ️ 'gh' CLI not found. GitHub Actions workflow will automatically build and publish the release upon pushing tag ${TAG}."
fi

echo "🎉 Release ${TAG} completed successfully!"
