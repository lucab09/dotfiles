# dotfiles

Personal macOS config files managed via symlinks.

## What's included

| Path | Tool |
|------|------|
| `.config/wezterm/` | WezTerm terminal |
| `.config/fish/` | Fish shell |
| `.config/zed/` | Zed editor |
| `.config/git/` | Git global ignore |
| `.config/starship.toml` | Starship prompt |

## Setup on a new machine

```bash
git clone https://github.com/lucamezzatesta/dotfiles.git ~/dotfiles
cd ~/dotfiles
chmod +x setup.sh
./setup.sh
```

The script symlinks each entry from `~/.config/` to this repo. Existing files are backed up with a `.bak` suffix.
