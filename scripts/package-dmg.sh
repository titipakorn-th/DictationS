#!/bin/sh
set -eu

version=${1:-0.1.0}
app="target/DictationS.app"
stage="target/DictationS-dmg"
dmg="target/DictationS-${version}.dmg"

./scripts/package-macos.sh
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto --rsrc --extattr "$app" "$stage/DictationS.app"
/bin/ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -volname "DictationS $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
printf 'Created %s\n' "$dmg"
