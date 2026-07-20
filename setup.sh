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
    info_plist="${swift_file%.swift}-Info.plist"
    compile_args=(-O "$swift_file" -o "$binary" -framework Cocoa -framework SwiftUI)

    if [ "$(basename "$swift_file")" = "calendar_notch.swift" ]; then
        compile_args+=(-framework EventKit -framework Contacts)
    fi

    if [ -f "$info_plist" ]; then
        compile_args+=(-Xlinker -sectcreate \
                      -Xlinker __TEXT \
                      -Xlinker __info_plist \
                      -Xlinker "$info_plist")
    fi

    echo "  compiling: $(basename "$binary")"
    if swiftc "${compile_args[@]}" 2>&1; then
        if [ -f "$info_plist" ]; then
            bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
            signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2; exit}')"
            if [ -z "$signing_identity" ]; then
                signing_identity="-"
            fi
            codesign --force --sign "$signing_identity" --identifier "$bundle_id" "$binary" 2>&1
        fi
        echo "  ok: $(basename "$binary")"
    else
        echo "  FAILED: $(basename "$binary") (swiftc error above)"
    fi
done

echo "Done."
