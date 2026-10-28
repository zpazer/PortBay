#!/bin/zsh
# Builds PortBay.app, installs it in ~/Applications and starts it.
set -euo pipefail
cd "${0:A:h}"

app=build/PortBay.app
rm -rf build
mkdir -p "$app/Contents/MacOS"
swiftc -O -target arm64-apple-macos13.0 Sources/PortBay.swift Sources/main.swift -o "$app/Contents/MacOS/PortBay"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

pkill -x PortBay || true
mkdir -p ~/Applications
rm -rf ~/Applications/PortBay.app
ditto "$app" ~/Applications/PortBay.app
open ~/Applications/PortBay.app
echo "Port Bay is running from ~/Applications/PortBay.app"
