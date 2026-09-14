#!/usr/bin/env python3
"""Install the shared workflow into pi, Claude Code, or both (stdlib only)."""
import argparse
from datetime import datetime
import os
from pathlib import Path
import shutil


SKILLS = ("brainstorm", "plan", "build")


def adapt_skill(content, harness):
    if harness == "pi":
        return content
    # Generated adapters only: the workflow itself is authored once in skills/.
    return (content.replace("`ask_user`", "`AskUserQuestion`")
            .replace("/skill:plan", "/workflow-plan")
            .replace("<skill-directory>", "${CLAUDE_SKILL_DIR}")
            .replace("name: plan\n", "name: workflow-plan\n"))


def resources(source, harness):
    files = {"workflow/plan.py": (source / "workflow/plan.py").read_bytes()}
    for name in SKILLS:
        command = "workflow-plan" if harness == "claude" and name == "plan" else name
        content = (source / f"skills/{name}/SKILL.md").read_text(encoding="utf-8")
        files[f"skills/{command}/SKILL.md"] = adapt_skill(content, harness).encode("utf-8")
    retired = []
    if harness == "pi":
        files["extensions/decision-selector.ts"] = (source / "extensions/decision-selector.ts").read_bytes()
    else:
        # /plan is a built-in command. Retain the old directory so the existing
        # non-force pi sync script sees an unmarked destination and skips it.
        files["skills/plan/.workflow-managed"] = (
            "The workflow Plan skill is installed as /workflow-plan.\n"
            "Do not sync pi skills here: rerun dotfiles/pi/install-workflow.sh --target all.\n"
        ).encode("utf-8")
        retired = ["skills/plan/SKILL.md"] + [
            f"skills/{name}/.pi-synced" for name in (*SKILLS, "workflow-plan")
        ]
    return files, retired


def preflight(target, paths):
    for relative in paths:
        dst = target / relative
        # Never mutate files in a user's external symlinked skill directory.
        for parent in dst.relative_to(target).parents:
            if (target / parent).is_symlink():
                raise ValueError(f"Refusing to write through directory symlink: {target / parent}")
        if dst.is_dir():
            raise ValueError(f"Expected file, found directory: {dst}")
    if (target / "backups").is_symlink():
        raise ValueError(f"Refusing symlinked backup directory: {target / 'backups'}")


def install(target, files, retired):
    backup = target / "backups" / f"workflow-{datetime.now():%Y%m%d-%H%M%S-%f}-{os.getpid()}"

    def save(dst, relative):
        if dst.exists() or dst.is_symlink():
            saved = backup / relative
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(dst), str(saved))

    for relative, content in files.items():
        dst = target / relative
        if dst.is_file() and not dst.is_symlink() and dst.read_bytes() == content:
            print(f"Unchanged: {dst}")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        save(dst, relative)
        dst.write_bytes(content)
        print(f"Installed: {dst}")
    for relative in retired:
        dst = target / relative
        if dst.exists() or dst.is_symlink():
            save(dst, relative)
            print(f"Retired (backed up): {dst}")
    if backup.exists():
        print(f"Previous versions: {backup}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("pi", "claude", "all"), default="pi",
                        help="Default: pi (backwards compatible)")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    roots = {
        "pi": Path(os.environ.get("PI_CODING_AGENT_DIR") or Path.home() / ".pi/agent").expanduser().absolute(),
        "claude": Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser().absolute(),
    }
    names = ("pi", "claude") if args.target == "all" else (args.target,)
    try:
        if args.target == "all" and (roots["pi"].resolve().is_relative_to(roots["claude"].resolve())
                                     or roots["claude"].resolve().is_relative_to(roots["pi"].resolve())):
            raise ValueError("pi and Claude config directories must not overlap")
        jobs = []
        # Validate both installations and read all sources before any mutation.
        for name in names:
            files, retired = resources(source, name)
            root = roots[name]
            if source.is_relative_to(root.resolve()) or root.resolve().is_relative_to(source):
                raise ValueError(f"Install directory overlaps workflow source: {root}")
            preflight(root, [*files, *retired])
            jobs.append((name, root, files, retired))
        for name, root, files, retired in jobs:
            install(root, files, retired)
            if name == "pi":
                print("Run /reload in pi. Preview with /decision-demo (no model call).")
            else:
                print("Claude Code: /brainstorm, /workflow-plan, /build. Check /skills or start a new session.")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Install error: {error}\n")


if __name__ == "__main__":
    main()
