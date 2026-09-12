#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$DIR/SwiftBar.swift"
CARD_COMPONENT="$DIR/../components/Card.swift"
BAR_COMPONENT="$DIR/../components/BarDesignSystem.swift"
BINARY="$DIR/swift_bar"
TEMP_BINARY="/tmp/sketchybar_swift_bar.build"
TEMP_SOURCE="/tmp/sketchybar_swift_bar.build.swift"
trap 'rm -f "$TEMP_BINARY" "$TEMP_SOURCE"' EXIT

# Swift accetta espressioni top-level soltanto quando compila un singolo
# sorgente; uniamo quindi i design system condivisi al punto d'ingresso.
cat "$CARD_COMPONENT" "$BAR_COMPONENT" "$SOURCE" >"$TEMP_SOURCE"
swiftc -swift-version 5 -O "$TEMP_SOURCE" -o "$TEMP_BINARY" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework CoreWLAN

mv "$TEMP_BINARY" "$BINARY"
chmod +x "$BINARY"
echo "Barra Swift compilata: $BINARY"
