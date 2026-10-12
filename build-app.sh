#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release --arch arm64
bin_dir="$(swift build --show-bin-path -c release)"

app=".build/DriveDock.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/DriveDock" "$app/Contents/MacOS/DriveDock"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
echo "Built $PWD/$app"
