#!/bin/bash
# Archives the Mac App Store edition (APPSTORE flag, sandboxed, no SSH) and uploads it
# to App Store Connect. Requires Xcode signed in to the Tweetso team (NWPTRYJ9FL).
# Usage: ./archive_upload.sh            # archive + upload
#        EXPORT_ONLY=1 ./archive_upload.sh  # archive + export a signed .pkg locally (no upload)
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate
ARCHIVE="$PWD/build/MacMonitor.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project MacMonitorAppStore.xcodeproj -scheme MacMonitor -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates archive
OPTS=ExportOptions.plist
if [[ "${EXPORT_ONLY:-0}" == "1" ]]; then
    sed 's#<string>upload</string>#<string>export</string>#' ExportOptions.plist > build/ExportOptions-local.plist
    OPTS=build/ExportOptions-local.plist
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" \
    -exportPath "$PWD/build/export" -allowProvisioningUpdates
