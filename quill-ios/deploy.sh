#!/bin/zsh
# One-command deploy: bump build → xcodegen → build → install to the
# connected iPhone → publish the version manifest the app's UpdateChecker
# reads. Usage: ./deploy.sh [--notes "what changed"]
set -e
cd "$(dirname "$0")"

DEVICE="9E73C8C5-971C-5811-990B-B226102F8468"
XCODEGEN="/tmp/xcodegen/xcodegen/bin/xcodegen"
NOTES="${2:-}"

# Build number = seconds since 2026-01-01, monotonic across machines.
BUILD=$(( $(date +%s) - 1767225600 ))
VERSION=$(grep -m1 'CFBundleShortVersionString' project.yml | sed 's/.*"\(.*\)".*/\1/')

sed -i '' "s/CFBundleVersion: \"[0-9]*\"/CFBundleVersion: \"$BUILD\"/" project.yml
"$XCODEGEN" generate > /dev/null

xcodebuild -project QuillIOS.xcodeproj -scheme QuillIOS \
  -destination "platform=iOS,id=$DEVICE" -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD" | head -5

APP=$(find ~/Library/Developer/Xcode/DerivedData/QuillIOS-*/Build/Products/Debug-iphoneos -maxdepth 1 -name quill.app | head -1)
xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
echo "installed build $BUILD"

# Publish the manifest (share worker keeps /s/quill-ios-version stable).
curl -s -X POST "https://brand-studio.sma1lboy.me/share?series=quill-ios-version&round=$BUILD&title=quill-ios%20$VERSION%20($BUILD)&by=deploy" \
  -H "Content-Type: text/html" \
  --data-binary "{\"version\":\"$VERSION\",\"build\":\"$BUILD\",\"notes\":\"$NOTES\"}" \
  -o /dev/null -w "manifest published (HTTP %{http_code})\n"

xcrun devicectl device process launch --terminate-existing --device "$DEVICE" me.sma1lboy.quill 2>/dev/null | grep -q Launched && echo launched
