#!/usr/bin/env python3
import os, json, subprocess
from pathlib import Path

WEZTERM = "/Applications/WezTerm.app/Contents/MacOS/wezterm"

storage_dir = Path("/Users/luca/Library/Application Support/Cursor/User/workspaceStorage")
results = []
for ws_file in storage_dir.glob("*/workspace.json"):
    try:
        mtime = ws_file.stat().st_mtime
        data = json.loads(ws_file.read_text())
        folder = data.get("folder", "")
        if folder.startswith("file://"):
            path = folder[7:]
            if os.path.isdir(path) and os.path.isdir(os.path.join(path, ".git")):
                results.append((mtime, path))
    except:
        pass

results.sort(reverse=True)
repos = [path for _, path in results[:10]]

for i in range(10):
    item = f"git_repo_{i}"
    if i < len(repos):
        path = repos[i]
        name = os.path.basename(path)
        click = f"{WEZTERM} start --cwd '{path}'; sketchybar --set git popup.drawing=off"
        subprocess.run([
            "sketchybar", "--set", item,
            f"label={name}",
            f"click_script={click}",
            "drawing=on"
        ])
    else:
        subprocess.run(["sketchybar", "--set", item, "drawing=off"])
