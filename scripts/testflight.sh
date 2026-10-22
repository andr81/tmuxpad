#!/usr/bin/env bash
# Archive the app and upload it to TestFlight (internal testing) under team Z5SCY74SMF.
#
#   scripts/testflight.sh BUILD_NUMBER      # e.g. scripts/testflight.sh 2
#
# BUILD_NUMBER must be greater than every build already uploaded for the current
# MARKETING_VERSION (project.yml). Signing and upload use the Apple ID Xcode is signed in with
# (Xcode → Settings → Accounts). Runs under the system bash 3.2 of macOS.
set -eu

if [[ $# -ne 1 ]] || ! [[ $1 =~ ^[0-9]+$ ]]; then
	echo "usage: scripts/testflight.sh BUILD_NUMBER" >&2
	exit 2
fi
build=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ARCHIVE=$ROOT/build/TmuxPad.xcarchive

cd "$ROOT"
xcodegen generate --quiet
rm -rf "$ARCHIVE" build/export
xcodebuild archive -project TmuxPad.xcodeproj -scheme TmuxPad -destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE" -skipPackagePluginValidation -allowProvisioningUpdates \
	DEVELOPMENT_TEAM=Z5SCY74SMF CURRENT_PROJECT_VERSION="$build" -quiet
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
	-exportPath build/export -allowProvisioningUpdates
echo "uploaded build $build; App Store Connect processes it in 10-30 min"
