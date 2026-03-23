#!/usr/bin/env bash
set -e

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Homebrew ────────────────────────────────────────────────────────────────
echo "==> Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  echo "  Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for the rest of this script (Apple Silicon)
  eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
else
  echo "  Homebrew already installed."
fi

# ── Dependencies ────────────────────────────────────────────────────────────
echo "==> Installing dependencies..."
brew bundle --file="$DOTFILES/Brewfile"

# ── Dotfiles symlinks ────────────────────────────────────────────────────────
echo "==> Linking dotfiles..."
"$DOTFILES/setup.sh"

# ── SketchyBar ───────────────────────────────────────────────────────────────
echo "==> Enabling SketchyBar..."
if brew services list | grep -q "sketchybar.*started"; then
  brew services restart sketchybar
  echo "  SketchyBar restarted."
else
  brew services start sketchybar
  echo "  SketchyBar started."
fi

echo ""
echo "All done!"
