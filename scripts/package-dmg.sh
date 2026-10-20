#!/bin/sh
set -eu

app="target/DictationS.app"
stage="target/DictationS-dmg"

./scripts/package-macos.sh
# The disk image carries the version the app bundle reports.
version=${1:-$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")}
dmg="target/DictationS-${version}.dmg"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto --rsrc --extattr "$app" "$stage/DictationS.app"
/bin/ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -volname "DictationS $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
printf 'Created %s\n' "$dmg"
