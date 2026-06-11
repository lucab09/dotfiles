#!/usr/bin/env bash
set -e

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HOME/.config"

symlink() {
    local src="$1"
    local dst="$2"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "  backup: $dst → $dst.bak"
        mv "$dst" "$dst.bak"
    fi
    ln -sfn "$src" "$dst"
    echo "  linked: $dst"
}

echo "Setting up dotfiles..."

# .config entries
for entry in "$DOTFILES/.config"/*/; do
    name="$(basename "$entry")"
    symlink "$entry" "$CONFIG/$name"
done

# starship.toml (file, not dir)
symlink "$DOTFILES/.config/starship.toml" "$CONFIG/starship.toml"

# Compile sketchybar Swift binaries
SKETCHYBAR_PLUGINS="$DOTFILES/.config/sketchybar/plugins"
for swift_file in "$SKETCHYBAR_PLUGINS"/*.swift; do
    binary="${swift_file%.swift}"
    echo "  compiling: $(basename "$binary")"
    swiftc -O "$swift_file" -o "$binary" -framework Cocoa -framework SwiftUI 2>&1 \
        && echo "  ok: $(basename "$binary")" \
        || echo "  FAILED: $(basename "$binary") (swiftc error above)"
done

echo "Done."
