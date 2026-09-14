---
name: plan
description: Inspect the relevant code and turn agreed scope into a concise, executable plan with complete worker context.
---

# Plan

Produce a decision-complete plan grounded in the repository. Do not edit implementation files.

## Flow

1. Read the relevant `.pi/brainstorm.md`, supplied references, and applicable repository instructions. Reuse confirmed intent; the latest user instruction wins. Do not overwrite an unrelated plan silently.
2. Inspect only the affected code, interfaces, tests, and build configuration. Discover facts yourself rather than asking the user. Record verified paths/symbols, commands, compatibility needs, and generated assets to rebuild.
3. Resolve only consequential unknowns. Use repository conventions for reversible details; state important defaults. If a product/interface/migration decision remains, ask one question with a recommendation. Do not delegate unresolved design choices to Build.
4. Write `.pi/plan.json` using the contract below. Run the helper to validate it and generate `.pi/plan.md`. Fix failures before declaring readiness. Stop here: planning is not authorization to build.

No mandatory approval between steps. Default chat turns to ≤150 words, in the user's language. Report only new findings, blockers, or the final summary. For choices use `ask_user` when available (2–4 concise options, recommendation, no duplicate question in chat); otherwise use a plain numbered question. Never emit `PI_CHOICES`. Cancellation, timeout, or no explicit answer means stop, not approval.

## Canonical plan

`.pi/plan.json` is the only authored source. `.pi/plan.md` is a generated reading view, never a second specification. All fields below are required; arrays may be empty unless stated otherwise.

```json
{
  "version": 2,
  "summary": "Goal and user-visible outcome",
  "context": {
    "baseRevision": "Inspected git HEAD, or non-git",
    "facts": ["Verified architecture/behavior, with source paths or symbols"],
    "decisions": ["Agreed product and technical choices; important rationale/defaults"],
    "constraints": ["Compatibility, security, cost and must-not-break requirements"],
    "nonGoals": ["Excluded work and areas not to touch"],
    "acceptance": ["Observable feature-level success criteria"],
    "validation": ["Exact integration commands with cwd; manual checks when needed"],
    "risks": ["Risk -> mitigation"],
    "readFirst": [{"path": "AGENTS.md", "why": "Applicable instructions; list only real files"}]
  },
  "tasks": [{
    "id": "T1",
    "title": "Action and tightly coupled concern",
    "files": ["src/example.ts"],
    "readFirst": [{"path": "src/existing.ts", "why": "Existing pattern or interface to follow"}],
    "what": "Exact changes: symbols/contracts, behavior, edge/error cases, generated assets if any",
    "doneWhen": "Concrete observable criterion, including exact focused verification command and cwd",
    "deps": []
  }]
}
```

- Keep shared facts/constraints in `context`, not copied into every task. A worker receives **context + its task + prerequisite outcomes**, never the task alone.
- `acceptance`, `validation`, `tasks`, and each task's `files` must be nonempty. Use repository-relative file paths; external references belong in facts/decisions with the needed content summarized. Never include secrets.
- Each task is one verifiable concern, not one file by decree. Keep tightly coupled implementation/tests together when splitting would add handoff cost. Name exact new contracts without prescribing irrelevant internals.
- `readFirst` names the minimal useful files and why. If a file will be created by a prerequisite, name that task in `why` and declare the dependency. Existing repo instructions belong in shared `readFirst`.
- Dependencies include execution order, shared-file writes, generated outputs, and interface consumers. Tasks editing the same file must be ordered, even if their changes seem independent.
- Include setup prerequisites and known baseline test failures in `context.facts`. A temporary reference or conversation-only decision is not sufficient context.

## Validate and hand off

Resolve the helper relative to this skill's directory (not the project cwd):

```sh
python3 "<skill-directory>/../../workflow/plan.py" check .pi/plan.json
python3 "<skill-directory>/../../workflow/plan.py" render .pi/plan.json
```

The check validates structure, dependency cycles, unordered file conflicts, and context-file availability; it cannot establish that the design or code is correct. Inspect those yourself.

Finish with the goal, task count (titles only when helpful), any material risk, and paths to `.pi/plan.json` / `.pi/plan.md`. Never print the full JSON, Markdown, or `<plan>` block. An external runner requiring inline `<plan>` must explicitly request that legacy transport; do not assume it exists. `<!-- PLAN_READY -->` may be used only when the current host explicitly requires it.
