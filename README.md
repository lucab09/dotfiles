# dotfiles

Reproducible macOS configuration managed with symlinks.

## Included

- Full-width Swift/AppKit status bar with glass background, calendar agenda, network and weather popups, compute stats, battery, and date/time
- Yabai
- Neovim / LazyVim
- WezTerm
- Zed
- Fish, Starship, Git, and personal tool configuration
- Native pi status bar with model, context, Git changes, thinking level, and subscription limits

## New Mac setup

Clone the repository and run the canonical bootstrap script:

```bash
git clone https://github.com/lucab09/dotfiles.git ~/dotfiles
cd ~/dotfiles
./setup.sh
```

`setup.sh` is idempotent and performs the complete bootstrap:

1. checks Xcode Command Line Tools and prompts for installation when missing;
2. installs Homebrew when needed;
3. installs the applications, tools, and fonts from `Brewfile`;
4. backs up existing config directories and creates symlinks into this repository, including the global pi status-bar extension;
5. configures the Calendar Notch OAuth client;
6. compiles and signs all Swift plugins and the main Swift status bar for the current Mac;
7. starts or restarts Yabai and the hidden SketchyBar supervisor that launches the Swift UI.

If Command Line Tools need to be installed, finish Apple's installer and run `./setup.sh` again.
`./install.sh` is retained as an alias for `./setup.sh`.

## Calendar Notch Google OAuth

The Desktop OAuth client JSON contains credentials and is intentionally not committed. Copy or download it securely onto the new Mac, then either let `setup.sh` find it in `~/Downloads`, enter its path when prompted, or provide it explicitly:

```bash
CALENDAR_NOTCH_OAUTH_JSON="$HOME/Downloads/client_secret.json" ./setup.sh
```

It is installed with mode `0600` at:

```text
~/Library/Application Support/Calendar Notch/google-oauth-client.json
```

The Google Cloud project must have Google Calendar API and Google People API enabled. OAuth tokens and photo caches are machine-local, so each Google account must be authorized again from Calendar Notch settings.

## First-run macOS permissions

On every new Mac:

- grant Accessibility permission to Yabai in **System Settings → Privacy & Security → Accessibility**;
- open Calendar Notch and grant Calendar and Contacts access when requested;
- authorize the required Google accounts from the gear button in Calendar Notch.

The calendar agenda supports the physical notch when present; the main Swift status bar remains the only visible bar across the full display width.

## Local-only credentials

These are intentionally excluded from Git and must be provisioned separately when needed:

- Calendar Notch OAuth client JSON described above;
- `.config/pmmgmt/gcal_credentials.json` for `pmmgmt`.
