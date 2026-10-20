#!/bin/sh
set -eu

# Remove the app from before the rename, before the new one is copied in. The
# name has to match exactly: the filesystem is case-insensitive, so a plain
# path check also matches the app that is about to be installed.
legacy=$(find /Applications -maxdepth 1 -name 'Dictations.app' -print)
if [ -n "$legacy" ]; then
	rm -rf "$legacy"
fi

./scripts/package-macos.sh
/usr/bin/ditto target/DictationS.app /Applications/DictationS.app
test -x /Applications/DictationS.app/Contents/MacOS/dictations
test -f /Applications/DictationS.app/Contents/Resources/DictationS.icns
printf 'Installed /Applications/DictationS.app\n'
