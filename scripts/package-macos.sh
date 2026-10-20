#!/bin/sh
set -eu

cargo build --release

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
app="target/DictationS.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
iconset="$app/Contents/Resources/DictationS.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" packaging/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
	double=$((size * 2))
	sips -z "$double" "$double" packaging/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/DictationS.icns"
rm -rf "$iconset"
cp target/release/dictations "$app/Contents/MacOS/dictations"
swiftc -parse-as-library -O -framework AppKit -framework Combine -framework SwiftUI scripts/status-island.swift scripts/update-check.swift -o "$app/Contents/MacOS/status-island"
cp packaging/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
printf 'Packaged %s\n' "$app"
