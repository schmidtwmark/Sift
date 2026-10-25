#!/bin/zsh
# Copies a built Sift.app into /Applications, replacing the old copy.
#
#   scripts/install-app.sh <path/to/Sift.app> [--open]
#
# Used by scripts/install-mac.sh and by the "Sift → Applications" Xcode
# scheme's post-build action. A running copy is quit first, so the next launch
# is the new build; --open launches it afterwards.
set -euo pipefail

source_app=${1:?usage: install-app.sh <path/to/Sift.app> [--open]}
destination=/Applications/Sift.app
staging=/Applications/.Sift.app.installing
log=~/Library/Logs/Sift-install.log

# Xcode runs this for every destination; only Mac builds belong in /Applications.
if [[ -n ${PLATFORM_NAME:-} && $PLATFORM_NAME != macosx ]]; then
    exit 0
fi

{
    echo "$(date '+%F %T') installing $source_app"

    # Quit the installed copy (not the simulator's, not one Xcode is debugging).
    if pids=$(pgrep -f "^$destination/Contents/MacOS/Sift"); then
        kill -TERM ${(f)pids} 2>/dev/null || true
        for _ in {1..50}; do
            pgrep -qf "^$destination/Contents/MacOS/Sift" || break
            sleep 0.1
        done
        pkill -KILL -f "^$destination/Contents/MacOS/Sift" 2>/dev/null || true
    fi

    # Copy beside the old app, then swap, so a failed copy leaves the old one.
    rm -rf "$staging"
    ditto "$source_app" "$staging"
    rm -rf "$destination"
    mv "$staging" "$destination"
    # A fresh modification date makes Finder and the Dock redraw the icon.
    touch "$destination"
    # Make Launch Services (Spotlight, notifications, Open at Login, email links)
    # use this copy, and forget the build-folder one so "Default email reader"
    # menus list Sift once.
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$lsregister" -f "$destination"
    "$lsregister" -u "$source_app" 2>/dev/null || true

    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination/Contents/Info.plist")
    echo "$(date '+%F %T') installed Sift $version at $destination"
} 2>&1 | tee -a "$log"

if [[ ${2:-} == --open ]]; then
    open "$destination"
fi
