#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$DIR/SwiftBar.swift"
BINARY="$DIR/swift_bar"
TEMP_BINARY="/tmp/sketchybar_swift_bar.build"

swiftc -swift-version 5 -O "$SOURCE" -o "$TEMP_BINARY" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework CoreWLAN

mv "$TEMP_BINARY" "$BINARY"
chmod +x "$BINARY"
echo "Barra Swift compilata: $BINARY"
