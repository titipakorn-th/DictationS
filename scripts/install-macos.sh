#!/bin/sh
set -eu

./scripts/package-macos.sh
/usr/bin/ditto target/DictationS.app /Applications/DictationS.app
test -x /Applications/DictationS.app/Contents/MacOS/dictations
test -f /Applications/DictationS.app/Contents/Resources/DictationS.icns
if [ -d /Applications/Dictations.app ]; then
	rm -rf /Applications/Dictations.app
fi
printf 'Installed /Applications/DictationS.app\n'
