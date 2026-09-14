---
name: build
description: Execute an approved plan, sequentially or with focused workers; verify outcomes and preserve resumable progress.
---

# Build

Implement the approved plan without scope creep. Instructions are not a spawn capability: verify which execution tools actually exist.

## Preflight

- Read `.pi/plan.json` and applicable repository instructions. The user invoking Build authorizes that plan unless they say otherwise; a Plan handoff alone does not.
- Run `python3 "<skill-directory>/../../workflow/plan.py" check .pi/plan.json` (resolve the helper from this skill's actual directory). Stop on failure. For legacy plans without shared context, read `.pi/plan.md` and obtain a Plan v2 migration before dispatch; never silently lose constraints.
- Inspect current HEAD, dirty files, required tooling and baseline checks. Compare with `context.baseRevision`; revalidate affected assumptions after drift. Do not reset, overwrite, or commit unrelated user changes.
- Read existing `.pi/build.json` before initializing. Store a SHA-256 of plan.json, base revision, task statuses/evidence, and integration status. If the plan hash differs, stop for reconciliation, not a silent reset. Recheck prior completed work against the current tree; interrupted `running` tasks need inspection, not blind replay.

## Execution

- Default to **sequential local execution** of all ready tasks. This is the fallback when no worker tool exists, not a reason to wait for an external runner.
- Delegate only when isolation or independent substantial work justifies duplicated context/startup cost. Do not spawn one agent per tiny file edit. Use Orca orchestration only when chosen/required, loading its skill then; do not load orchestration docs for a local build.
- **Single-task worker mode** applies only when explicitly assigned one task by a runner. Require shared context plus the task (read the relevant plan if omitted); if unavailable, report BLOCKED. Implement and verify only that task; do not spawn workers or update the coordinator's state.
- A task is ready only when all dependencies are verified and integrated. Parallel tasks must have disjoint write sets, including lockfiles/generated assets. Otherwise serialize.
- Before dispatch, generate a brief with `python3 "<skill-directory>/../../workflow/plan.py" brief .pi/plan.json T1 --output "<brief-path>"`. Add actual worker cwd, applicable instructions not in the plan, and prerequisite outcomes (changed contracts/files, verification, integrated revision). Include relevant assets/artifacts; confirm every referenced path is accessible in the worker checkout. Never assume another agent sees the parent's chat, filesystem changes, or branch.
- The brief includes shared context and only the assigned task. Workers read the listed sources, implement only that concern, run its check, and return task ID, changed files/revision, check results, and blockers in ≤8 lines. No full diffs or repeated plans.
- Missing consequential decisions, unavailable references, or a stale contract are blockers. Do not tell workers to guess a “conservative interpretation.” Use existing conventions only for immaterial implementation details.

## Verify and persist

For each task: `pending -> running -> done | blocked`. Coordinator owns `.pi/build.json`; workers never race to write it.

- Inspect the result and diff. Integrate worker changes into the target checkout before marking done or releasing dependents; isolated worktrees do not share changes automatically.
- Verify `doneWhen` against the integrated tree. Reuse trustworthy machine-recorded checks only for the exact same tree/environment; otherwise rerun. A symbol grep alone does not prove behavior. Keep focused checks per task; run expensive full integration once at the end unless risk requires more.
- Record command, cwd, result, relevant revision/artifact, and blocker reason in `.pi/build.json`. Preserve successful independent branches when another blocks; never release its dependents.
- Run `context.validation` and check feature-level acceptance after integration. Persist overall `passed`, `failed`, or `not-run` separately from task completion. Report missing manual verification honestly.
- Generate `.pi/build.md` once at the end as a concise human summary of outcomes, integration evidence, and remaining risks/blockers. Do not duplicate full task descriptions.

## Communication

Use the user's language. No per-tool narration or repeated worker reports. Chat only meaningful milestones/blockers; finish in ≤5 bullets with outcome, verification, remaining work, and artifact paths. Suggest Review, never start a merge/deploy automatically.

For blocking choices call `ask_user` if available, with concise options and a recommendation; do not repeat them in chat. Otherwise ask a plain numbered question. Never emit `PI_CHOICES`. Cancellation, timeout, or no explicit answer is not consent; stop and wait. Do not reopen the same question immediately.

Only an explicit legacy single-task runner gets `<task>COMPLETE</task>`, and only after verified success. Never emit that marker for a partial or blocked full build.
