#!/bin/zsh
# Builds PortBay.app, installs it in ~/Applications and starts it.
# With --release, builds it for Apple Silicon and Intel and zips it for GitHub Releases instead.
set -euo pipefail
cd "${0:A:h}"

app=build/PortBay.app
sources=(Sources/PortBay.swift Sources/main.swift)
rm -rf build
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"

if [[ "${1:-}" == "--release" ]]; then
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos13.0" "${sources[@]}" -o "build/PortBay-$arch"
    done
    lipo -create build/PortBay-arm64 build/PortBay-x86_64 -output "$app/Contents/MacOS/PortBay"
    codesign --force --sign - "$app"
    version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    ditto -c -k --norsrc --keepParent "$app" "build/PortBay-$version.zip"
    echo "build/PortBay-$version.zip"
    exit 0
fi

swiftc -O -target "$(uname -m)-apple-macos13.0" "${sources[@]}" -o "$app/Contents/MacOS/PortBay"
codesign --force --sign - "$app"

pkill -x PortBay || true
mkdir -p ~/Applications
rm -rf ~/Applications/PortBay.app
ditto "$app" ~/Applications/PortBay.app
open ~/Applications/PortBay.app
echo "Port Bay is running from ~/Applications/PortBay.app"
