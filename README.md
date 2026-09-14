# dotfiles

Reproducible macOS configuration managed with symlinks.

## Included

- Full-width Swift/AppKit status bar with glass background, calendar agenda, network and weather popups, compute stats, battery, WHOOP sleep quality, and date/time
- Yabai
- Neovim / LazyVim
- WezTerm
- Zed
- Fish, Starship, Git, and personal tool configuration
- Native pi status bar with model, context, Git changes, thinking level, and subscription limits
- [Shared pi / Claude Code workflow](pi/README.md): Brainstorm, Plan, Build, validated worker briefs, and host-native decision selectors

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
4. backs up existing config directories and creates symlinks into this repository, including the global pi status-bar extension, plus backed-up snapshots of the shared pi / Claude Code workflow skills and pi decision selector;
5. configures the Calendar Notch OAuth client;
6. compiles and signs all Swift plugins and the main Swift status bar for the current Mac;
7. installs the `com.luca.whoop-archive` LaunchAgent that archives WHOOP data every 30 minutes;
8. starts or restarts Yabai and the hidden SketchyBar supervisor that launches the Swift UI.

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

## WHOOP health widget

The `Health` cluster on the left of the bar shows WHOOP sleep performance, recovery and day strain, plus a dumbbell icon with the number of workouts this week (clicking it opens a scrollable card with each workout's detail). It talks to the official WHOOP v2 developer API over OAuth; no credentials are committed.

OAuth scopes requested: `read:sleep read:recovery read:cycles read:workout read:profile offline`. After adding `read:workout` an existing install must re-run `whoop_auth.py` once to re-consent (make sure the scope is enabled on the app at developer.whoop.com).

One-time setup on a new Mac:

1. On <https://developer.whoop.com> open your app and add `http://localhost:8789/callback` to its **Redirect URLs**.
2. Run the bootstrap with your app credentials:

   ```bash
   python3 ~/.config/sketchybar/plugins/whoop_auth.py \
     --client-id "<CLIENT_ID>" --client-secret "<CLIENT_SECRET>"
   ```

   Authorize in the browser. Tokens are written with mode `0600` to:

   ```text
   ~/Library/Application Support/Sketchybar Health/whoop.json
   ```

`plugins/whoop.py` refreshes the rotating token on its own and writes `/tmp/sketchybar_health_state.json`; the Swift bar only reads that file. A paid WHOOP membership is required for the OAuth flow to complete.

### History archive

`plugins/whoop_archive.sh` runs every 30 minutes via the `com.luca.whoop-archive` LaunchAgent: it calls `whoop.py`, then `git pull --rebase` / append / `commit` / `push` into a dedicated private repo, appending one line to `data/YYYY-MM.ndjson` only when sleep/recovery/strain changed. Any network failure is non-fatal and retried on the next run.

```bash
git clone git@github.com:lucab09/whoop-history.git \
  "$HOME/Library/Application Support/Sketchybar Health/history"
sh ~/.config/sketchybar/plugins/whoop_archive.sh install
```

Override the location with `WHOOP_HISTORY_DIR`. Until the repo is cloned the script just updates the widget data and skips the git step. Log: `/tmp/whoop_archive.log`.

## First-run macOS permissions

On every new Mac:

- grant Accessibility permission to Yabai in **System Settings → Privacy & Security → Accessibility**;
- open Calendar Notch and grant Calendar and Contacts access when requested;
- authorize the required Google accounts from the gear button in Calendar Notch.

The calendar agenda supports the physical notch when present; the main Swift status bar remains the only visible bar across the full display width.

## Local-only credentials

These are intentionally excluded from Git and must be provisioned separately when needed:

- Calendar Notch OAuth client JSON described above;
- `.config/pmmgmt/gcal_credentials.json` for `pmmgmt`;
- `~/Library/Application Support/Sketchybar Health/whoop.json` for the WHOOP health widget.
