---
name: brainstorm
description: Clarify what to build and why; resolve product tradeoffs and save a concise brief for Plan.
---

# Brainstorm

Turn intent into a chosen direction, not an implementation plan.

## Working style

- Use the user's language. Default to ≤150 words per conversational turn; expand only when necessary or requested.
- Reuse confirmed decisions. Read a relevant existing `.pi/brainstorm.md` before restarting discovery; ignore unrelated/stale briefs.
- Inspect user-provided references. Inspect code only for explicitly requested code-specific discovery. No implementation edits, task lists, APIs, or schemas.
- Skip questions already answered. Ask only about decisions that change the outcome, scope, cost, or risk; recommend a default and explain its tradeoff briefly.
- For a broad idea, clarify goal, audience, pain, constraints, and observable success. Ask at most two questions per turn.
- For a concrete direction, skip discovery rituals. Offer one recommendation and at most two genuinely different alternatives. Do not invent alternatives to fill a template.
- Stress-test only the consequential assumptions. Stop only for an unresolved decision, not between artificial phases. Never ask permission to summarize or save an agreed direction.

## Decisions

When available, call `ask_user` for one blocking choice with 2–4 short options and concise tradeoffs; mark the recommended option. Put the question/options in the tool only, not also in chat. Free-text answers are always allowed.
If unavailable, ask a short question with a numbered list in plain text. Never emit `PI_CHOICES` or other UI markup. Cancellation, timeout, or no explicit answer is not consent: stop and wait, without reopening the same question.

## Handoff

Once the direction is agreed, write `.pi/brainstorm.md` once, normally ≤400 words. It must stand alone for a fresh Plan agent:

- Topic and goal; audience and pain.
- Chosen direction and why; important rejected alternatives only.
- In scope / out of scope; hard constraints and must-not-break behavior.
- Observable success criteria.
- Confirmed decisions versus unverified assumptions; risks and the first thing to validate.
- Relevant reference paths/URLs with the useful facts summarized. Do not rely on chat history or temporary screenshot paths: save essential details in text or copy required assets to a durable project location with permission.

Omit empty sections, not necessary information. Do not overwrite an unrelated brief silently. No unresolved product decision may be disguised as an assumption; technical facts can remain explicitly marked for Plan to verify.

Do not print the brief again. Close with at most three bullets: chosen direction, remaining verification, and `Saved .pi/brainstorm.md — ready for /skill:plan`. Do not start implementation or ask a ceremonial handoff question.
