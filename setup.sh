#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HOME/.config"
OAUTH_DIR="$HOME/Library/Application Support/Calendar Notch"
OAUTH_DEST="$OAUTH_DIR/google-oauth-client.json"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This setup supports macOS only." >&2
    exit 1
fi

ensure_command_line_tools() {
    if xcrun --find swiftc >/dev/null 2>&1; then
        return
    fi

    echo "==> Xcode Command Line Tools are required."
    xcode-select --install 2>/dev/null || true
    echo "Complete the Apple installer, then run ./setup.sh again."
    exit 1
}

ensure_homebrew() {
    echo "==> Checking Homebrew..."
    if ! command -v brew >/dev/null 2>&1; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    command -v brew >/dev/null 2>&1 || {
        echo "Homebrew installation was not added to PATH." >&2
        exit 1
    }
}

symlink() {
    local src="$1"
    local dst="$2"

    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        local backup="$dst.bak"
        if [ -e "$backup" ]; then
            backup="$dst.bak.$(date +%Y%m%d%H%M%S)"
        fi
        echo "  backup: $dst -> $backup"
        mv "$dst" "$backup"
    fi
    ln -sfn "$src" "$dst"
    echo "  linked: $dst"
}

validate_oauth_config() {
    python3 - "$1" <<'PY'
import json
import os
import sys
from urllib.parse import urlparse

path = os.path.expanduser(sys.argv[1])
try:
    with open(path, encoding="utf-8") as handle:
        installed = json.load(handle)["installed"]
except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
    raise SystemExit(f"Invalid Google OAuth client JSON: {error}")

required = ("client_id", "client_secret", "auth_uri", "token_uri", "redirect_uris")
if any(not installed.get(key) for key in required):
    raise SystemExit("Invalid Google OAuth client JSON: missing installed-app fields")
if not any(
    urlparse(uri).scheme == "http" and urlparse(uri).hostname in {"localhost", "127.0.0.1"}
    for uri in installed["redirect_uris"]
):
    raise SystemExit("Invalid Google OAuth client JSON: a localhost redirect URI is required")
PY
}

install_oauth_config() {
    if [ -f "$OAUTH_DEST" ]; then
        validate_oauth_config "$OAUTH_DEST"
        chmod 600 "$OAUTH_DEST"
        echo "  Google OAuth client: already configured"
        return
    fi

    local source="${CALENDAR_NOTCH_OAUTH_JSON:-}"
    if [ -z "$source" ] && [ -t 0 ]; then
        local candidate=""
        candidate="$(find "$HOME/Downloads" -maxdepth 1 -type f \( -name 'client_secret*.json' -o -name '*oauth*client*.json' \) -print 2>/dev/null | head -1 || true)"
        echo ""
        echo "Calendar Notch needs the Desktop OAuth client JSON from Google Cloud."
        if [ -n "$candidate" ]; then
            read -r -p "OAuth JSON path [$candidate]: " source
            source="${source:-$candidate}"
        else
            read -r -p "OAuth JSON path (leave empty to configure later): " source
        fi
    fi

    source="${source/#\~/$HOME}"
    if [ -z "$source" ]; then
        echo "  warning: Google OAuth client not configured"
        echo "  rerun with CALENDAR_NOTCH_OAUTH_JSON=/path/to/client_secret.json"
        return
    fi
    if [ ! -f "$source" ]; then
        echo "Google OAuth client JSON not found: $source" >&2
        exit 1
    fi

    validate_oauth_config "$source"
    mkdir -p "$OAUTH_DIR"
    install -m 600 "$source" "$OAUTH_DEST"
    echo "  Google OAuth client installed at $OAUTH_DEST"
}

compile_swift_plugins() {
    local plugins="$DOTFILES/.config/sketchybar/plugins"
    local swift_file binary info_plist bundle_id signing_identity name app_bundle
    local -a compile_args

    signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2; exit}')"
    signing_identity="${signing_identity:--}"

    shopt -s nullglob
    for swift_file in "$plugins"/*.swift; do
        name="$(basename "${swift_file%.swift}")"
        binary="${swift_file%.swift}"
        info_plist="${swift_file%.swift}-Info.plist"
        compile_args=(-O "$swift_file" -o "$binary" -framework Cocoa -framework SwiftUI)

        if [ "$name" = "calendar_notch" ]; then
            compile_args+=(-framework EventKit -framework Contacts -framework CryptoKit -framework Network -framework Security)
        fi

        if [ "$name" = "geolocate" ]; then
            compile_args+=(-framework CoreLocation)
        fi

        if [ -f "$info_plist" ]; then
            compile_args+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$info_plist")
        fi

        echo "  compiling: $name"
        swiftc "${compile_args[@]}"

        if [ -f "$info_plist" ]; then
            bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
            codesign --force --sign "$signing_identity" --identifier "$bundle_id" "$binary"
            codesign --verify --strict "$binary"
        fi

        # geolocate deve girare come vera .app (via `open`): un binario nudo
        # eredita il processo "responsabile" TCC di chi lo lancia e il prompt
        # di autorizzazione Location Services non compare mai.
        if [ "$name" = "geolocate" ]; then
            app_bundle="$plugins/Geolocate.app"
            rm -rf "$app_bundle"
            mkdir -p "$app_bundle/Contents/MacOS"
            cp "$binary" "$app_bundle/Contents/MacOS/geolocate"
            cp "$info_plist" "$app_bundle/Contents/Info.plist"
            codesign --force --sign "$signing_identity" --identifier "$bundle_id" "$app_bundle"
            codesign --verify --strict "$app_bundle"
            echo "  ok: Geolocate.app"
        fi

        echo "  ok: $name"
    done
}

restart_brew_service() {
    local service="$1"
    if brew services list | awk -v name="$service" '$1 == name && $2 == "started" { found=1 } END { exit !found }'; then
        brew services restart "$service"
    else
        brew services start "$service"
    fi
    echo "  service ready: $service"
}

restart_yabai_service() {
    if ! yabai --restart-service >/dev/null 2>&1; then
        yabai --start-service
    fi
    echo "  service ready: yabai"
}

ensure_command_line_tools
ensure_homebrew

echo "==> Installing Homebrew dependencies..."
brew tap felixkratz/formulae
brew tap koekeishiya/formulae
brew trust --formula felixkratz/formulae/sketchybar >/dev/null 2>&1 || true
brew trust --formula koekeishiya/formulae/yabai >/dev/null 2>&1 || true
brew bundle install --no-upgrade --file="$DOTFILES/Brewfile"

echo "==> Linking dotfiles..."
mkdir -p "$CONFIG"
for entry in "$DOTFILES/.config"/*/; do
    symlink "$entry" "$CONFIG/$(basename "$entry")"
done
symlink "$DOTFILES/.config/starship.toml" "$CONFIG/starship.toml"

echo "==> Configuring Calendar Notch OAuth..."
install_oauth_config

echo "==> Compiling Swift plugins..."
compile_swift_plugins

echo "==> Starting services..."
restart_yabai_service
restart_brew_service sketchybar

echo ""
echo "Setup complete."
echo "On a new Mac, grant Accessibility to yabai and Calendar/Contacts access when Calendar Notch asks."
echo "Google accounts must be authorized again from the Calendar Notch settings window."
