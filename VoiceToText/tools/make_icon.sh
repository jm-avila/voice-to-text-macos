#!/bin/zsh
# Draws the icon (tools/draw_icon.swift) and writes Resources/AppIcon.icns.
# build.sh runs this when the drawing changed. Works with Command Line Tools
# only: iconutil ships with macOS, actool needs Xcode.
set -euo pipefail
here=${0:A:h}
repo=${here:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$repo/Resources"
swift "$here/draw_icon.swift" "$work/AppIcon.iconset" >/dev/null
iconutil -c icns "$work/AppIcon.iconset" -o "$repo/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
