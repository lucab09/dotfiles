#!/usr/bin/env python3
"""Validate, render, or extract a worker brief from .pi/plan.json (stdlib only)."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


CONTEXT_LISTS = (
    "facts", "decisions", "constraints", "nonGoals", "acceptance", "validation", "risks"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text(value):
    return isinstance(value, str) and bool(value.strip())


def strings(value, label, nonempty=False):
    require(isinstance(value, list) and all(text(v) for v in value),
            f"{label}: expected an array of nonempty strings")
    require(not nonempty or bool(value), f"{label}: must not be empty")


def path_value(value, root):
    require(text(value), "file path must be a nonempty string")
    p = PurePosixPath(value)
    require(not p.is_absolute() and str(p) == value and ".." not in p.parts
            and "\\" not in value and value != ".", f"invalid relative file path: {value}")
    require((root / value).resolve().is_relative_to(root.resolve()),
            f"path escapes project (including symlinks): {value}")


def reads(value, label, root):
    require(isinstance(value, list), f"{label}: expected an array")
    for entry in value:
        require(isinstance(entry, dict) and text(entry.get("why")),
                f"{label}: each entry needs path and why")
        path_value(entry.get("path"), root)


def validate(plan, root):
    require(isinstance(plan, dict) and plan.get("version") == 2,
            "Plan v2 required: migrate legacy shared context before execution")
    require(text(plan.get("summary")), "summary is required")
    context = plan.get("context")
    require(isinstance(context, dict), "shared context is required")
    require(text(context.get("baseRevision")), "context.baseRevision is required")
    for key in CONTEXT_LISTS:
        strings(context.get(key), f"context.{key}", key in ("acceptance", "validation"))
    reads(context.get("readFirst"), "context.readFirst", root)
    tasks = plan.get("tasks")
    require(isinstance(tasks, list) and tasks, "tasks must be a nonempty array")
    by_id = {}
    for task in tasks:
        require(isinstance(task, dict), "task must be an object")
        for key in ("id", "title", "what", "doneWhen"):
            require(text(task.get(key)), f"task.{key} is required")
        tid = task["id"]
        require(tid not in by_id, f"duplicate task id: {tid}")
        by_id[tid] = task
        strings(task.get("files"), f"{tid}.files", True)
        for path in task["files"]:
            path_value(path, root)
        reads(task.get("readFirst"), f"{tid}.readFirst", root)
        strings(task.get("deps"), f"{tid}.deps")
        require(len(set(task["deps"])) == len(task["deps"]), f"{tid}: duplicate dependency")
    ancestors, visiting = {}, set()

    def visit(tid):
        require(tid in by_id, f"unknown dependency: {tid}")
        require(tid not in visiting, f"dependency cycle at: {tid}")
        if tid not in ancestors:
            visiting.add(tid)
            result = set()
            for dep in by_id[tid]["deps"]:
                result.add(dep)
                result.update(visit(dep))
            visiting.remove(tid)
            ancestors[tid] = result
        return ancestors[tid]

    for tid in by_id:
        visit(tid)
    for i, left in enumerate(tasks):
        for right in tasks[i + 1:]:
            shared = ({(root / p).resolve() for p in left["files"]}
                      & {(root / p).resolve() for p in right["files"]})
            ordered = left["id"] in ancestors[right["id"]] or right["id"] in ancestors[left["id"]]
            require(not shared or ordered,
                    f"unordered write conflict: {left['id']} / {right['id']}: {sorted(map(str, shared))}")
    for entry in context["readFirst"]:
        require((root / entry["path"]).is_file(), f"missing shared context: {entry['path']}")
    for task in tasks:
        generated = {p for dep in ancestors[task["id"]] for p in by_id[dep]["files"]}
        for entry in task["readFirst"]:
            require((root / entry["path"]).is_file() or entry["path"] in generated,
                    f"{task['id']}: missing readFirst file without prerequisite producer: {entry['path']}")
    return plan


def context_markdown(plan):
    context = plan["context"]
    lines = [f"# {plan['summary']}", "", f"Base revision: `{context['baseRevision']}`"]
    for key in CONTEXT_LISTS:
        if context[key]:
            lines += ["", f"## {key}"] + [f"- {item}" for item in context[key]]
    if context["readFirst"]:
        lines += ["", "## Shared read first"]
        lines += [f"- `{r['path']}` — {r['why']}" for r in context["readFirst"]]
    return lines


def task_markdown(task):
    return [
        "", f"## {task['id']}: {task['title']}",
        "Files: " + ", ".join(f"`{p}`" for p in task["files"]),
        "Dependencies: " + (", ".join(task["deps"]) or "none"),
        "", task["what"], "", "Read first:",
        *[f"- `{r['path']}` — {r['why']}" for r in task["readFirst"]],
        "", f"Done when: {task['doneWhen']}",
    ]


def render(plan):
    lines = ["<!-- Generated from plan.json; do not edit. -->", *context_markdown(plan)]
    for task in plan["tasks"]:
        lines += task_markdown(task)
    return "\n".join(lines) + "\n"


def brief(plan, tid):
    task = next((t for t in plan["tasks"] if t["id"] == tid), None)
    require(task is not None, f"unknown task: {tid}")
    lines = [
        "Implement only the assigned task. Read shared and task context before editing.",
        "Follow applicable repository instructions. No unrelated edits or nested delegation.",
        "If a consequential decision/reference is missing, stop with BLOCKED; do not guess.",
        "Verify doneWhen. Return ID, changed files/revision, checks/results and blockers in <=8 lines.",
        "Do not write coordinator build state. Do not assume dependencies are integrated: verify their contracts.",
        "", *context_markdown(plan), *task_markdown(task),
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "render", "brief"))
    parser.add_argument("plan", type=Path, help="Path to <project>/.pi/plan.json")
    parser.add_argument("task", nargs="?")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        raw = args.plan.read_bytes()
        plan = validate(json.loads(raw), args.plan.resolve().parent.parent)
        if args.command == "check":
            print(f"Valid: {len(plan['tasks'])} tasks; sha256={hashlib.sha256(raw).hexdigest()}")
            return
        if args.command == "render":
            output = args.output or args.plan.with_suffix(".md")
            content = render(plan)
        else:
            require(args.task is not None, "brief requires a task id")
            output, content = args.output, brief(plan, args.task)
        if output:
            require(output.resolve() != args.plan.resolve(), "output must not overwrite the source plan")
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(content, encoding="utf-8")
            print(f"Saved {output}")
        else:
            print(content, end="")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Plan error: {error}\n")


if __name__ == "__main__":
    main()
