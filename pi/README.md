# Lean workflow for pi and Claude Code

One source for `brainstorm → plan → build`, with generated host adapters. Install without Homebrew or restarting desktop services:

```sh
bash pi/install-workflow.sh --target all     # pi + Claude Code
bash pi/install-workflow.sh --target claude  # Claude Code only
bash pi/install-workflow.sh                 # pi only (unchanged default)
```

The full `setup.sh` installs both. Python 3.9+ is required; no new packages, models, MCP servers, permission grants, or paid services are configured.

| Host | Commands | Decisions | Install directory |
| --- | --- | --- | --- |
| pi | `/skill:brainstorm`, `/skill:plan`, `/skill:build` | Custom `ask_user` TUI | `${PI_CODING_AGENT_DIR:-~/.pi/agent}` |
| Claude Code | `/brainstorm`, `/workflow-plan`, `/build` | Native `AskUserQuestion`, including Other/free text | `${CLAUDE_CONFIG_DIR:-~/.claude}` |

Run `/reload` in pi; `/decision-demo` previews its selector without an LLM call. In Claude Code check `/skills`; start a new session if the old skill content was already loaded. **Claude's `/plan` is its built-in permission mode, not this workflow skill.** Use `/workflow-plan` to generate the shared plan. Normal Claude permissions still apply; the installer does not enable bypass mode. Personal skills are available across local projects, not automatically in Cowork or remote/cloud sessions.

## Shared source and updates

Author only `skills/*/SKILL.md` and `workflow/plan.py` in this directory. `workflow/install.py` derives the Claude variants: native question tool, `/workflow-plan` name/handoff, and `${CLAUDE_SKILL_DIR}` for reliable helper paths. The helper is installed into each host's `workflow/` directory. Do not edit the generated global copies independently; rerun `--target all` after source changes.

Both hosts keep project artifacts in **the same `.pi/` directory**. This intentionally avoids two divergent plans/build states and allows switching hosts on the same checkout. Transfer the brief and artifacts explicitly to another checkout; do not run two Builds concurrently on the same files/state.

The installer copies snapshots, not symlinks into temporary worktrees. All sources and destinations are preflighted before changes; symlinked destination directories and overlapping host roots are rejected. Replaced/retired files are backed up under each host's `backups/workflow-<timestamp>-<pid>/`, outside skill discovery. Unrelated files (including Build's existing `config.json`, settings, and other skills) are preserved. Reinstalling unchanged content creates no backup. To roll back, restore the backed-up files and remove newly installed resources you no longer want, then reload/restart the host.

### Existing pi-to-Claude sync

The local legacy `sync-pi-skills-to-claude.sh` copies raw skill directories, not host adapters. Installation backs up/removes `.pi-synced` markers only for these managed Claude skills, so that script's normal mode skips them. The old Claude `skills/plan/SKILL.md` is retired into backup; its directory stays with `.workflow-managed`, preventing ordinary sync from recreating a conflicting `/plan` skill. `/workflow-plan` is the replacement. The sync script itself and other synced skills are untouched. **Do not use that script's `--force` for these skills**: update them with this installer instead.

## What changed

- No mandatory confirmation between phases; only decisions that materially change the work interrupt it.
- Short chat summaries. Full artifacts are written once, not pasted back into the conversation.
- `brainstorm.md` captures decisions, scope, success, constraints, and durable references for a fresh agent.
- `plan.json` v2 is canonical. `plan.md` is generated deterministically, not authored again by the model.
- Workers receive shared context + one task + actual prerequisite outcomes and checkout details. They must have access to referenced sources/artifacts before starting.
- Build defaults to sequential execution. Delegation is optional when its benefit outweighs context/startup costs. No hidden agent runtime or model selection is installed; existing runner config is not interpreted by this workflow.
- Resume instructions preserve evidence and plan identity; integration/acceptance failures cannot be hidden by all tasks having status `done`.

These are agent instructions plus a structural plan validator, not a guarantee that an agent follows every instruction or that a design is correct. The validator does not execute tests, verify technical claims, supervise workers, or integrate branches. Build must perform those checks.

## Decision selector

`extensions/decision-selector.ts` registers `ask_user`. It uses pi's native `SelectList` inside a themed custom TUI component, not HTML/DOM:

- 2–4 options, highlighted selection, `★` recommendation and full selected-option description;
- configured up/down, confirm/cancel keys; numbers highlight but do not auto-submit;
- free-text answer; Escape in the free-text input returns to options;
- cancellation stops the tool turn and never implies approval;
- compact transcript result; options visible on expansion, not repeated by default;
- native select/input fallback for RPC; print/JSON returns `needs_input` for the agent to ask in plain text, never an invented selection;
- no message scraping, auto-injected prompts, or extra LLM call just to render a selector.

The three updated skills stop emitting `PI_CHOICES`. Historical messages and other skills using that legacy marker are not rewritten. The tool schema adds a small fixed context cost; the expected savings come from shorter skills, fewer turns and avoiding repeated artifacts, not from claiming the UI itself eliminates all tokens.

## Plan helper

Python 3.9+; no dependencies. Run from the project being planned, replacing `<workflow>` with either host's installed workflow directory (`~/.pi/agent/workflow` or `~/.claude/workflow` by default):

```sh
python3 "<workflow>/plan.py" check .pi/plan.json
python3 "<workflow>/plan.py" render .pi/plan.json
python3 "<workflow>/plan.py" brief .pi/plan.json T1 --output .pi/briefs/T1.md
```

The plan must live at `<project>/.pi/plan.json`; file references are project-relative. `check` validates v2 structure, unique IDs, missing/cyclic dependencies, unordered same-file writers, and available `readFirst` files (or declared prerequisite producers). It prints a SHA-256 for Build's resume identity. `render` regenerates the Markdown view. `brief` includes shared constraints/acceptance and only the requested task. The coordinator must add runtime cwd, integrated prerequisite outcomes, and any additional applicable instructions before dispatch.

### Compatibility

Task fields retain their old names, but v2 also requires shared `context`. Old plans must be migrated deliberately, using their Markdown context; the helper rejects them rather than silently executing incomplete tasks. External runners that pass only individual task fields must switch to `brief` (plus prerequisite outcomes) or otherwise include shared context. Inline `<plan>`, `PLAN_READY`, and `COMPLETE` are legacy transport conventions, **not** native pi APIs. No external Orca runner/parser is changed or verified here; a runner that requires those conventions needs an explicit compatibility adapter/request. Normal pi uses files and the selector tool directly.

## Tests

```sh
python3 -m unittest discover -s pi/tests -p 'test_*.py' -v
node --test pi/tests/decision-selector.test.mjs
python3 pi/tests/tui-smoke.py
bash -n pi/install-workflow.sh setup.sh
```

Installer tests cover both targets, generated adapters, backup/retirement, legacy sync markers, idempotence, preflight safety, and running Claude's installed helper from an unrelated cwd with spaces. They make no model calls. Claude's documented [skill locations and command naming](https://code.claude.com/docs/en/skills#how-a-skill-gets-its-command-name) and [native question tool](https://code.claude.com/docs/en/tools-reference#askuserquestion-tool-behavior) are used without custom UI hooks.

JS tests use the installed pi package and its dependencies (`npm root -g` or `PI_PACKAGE_DIR`). They cover registration, keys, free text, cancellation/abort, RPC/headless behavior and narrow Unicode rendering. The PTY smoke test launches a separate offline pi with a temporary agent directory and exercises `/decision-demo`; no model calls or global settings changes.
