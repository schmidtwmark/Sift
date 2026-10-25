#!/bin/zsh
# Builds Sift for the Mac (Release) and installs it as /Applications/Sift.app.
#
#   scripts/install-mac.sh            build, install, launch
#   scripts/install-mac.sh --no-open  build and install only
set -euo pipefail
cd "${0:A:h}/.."

# Outside ~/Documents: iCloud syncing build products breaks code signing.
derived=~/Library/Caches/Sift-Release

echo "Building Sift (Release, macOS)…"
xcodebuild -project Sift.xcodeproj -scheme Sift -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -allowProvisioningUpdates -quiet build

open_flag=--open
[[ ${1:-} == --no-open ]] && open_flag=""
scripts/install-app.sh "$derived/Build/Products/Release/Sift.app" $open_flag
