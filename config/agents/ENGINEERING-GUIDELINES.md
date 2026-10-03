# ENGINEERING-GUIDELINES.md

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- Keep small, localized, well-understood tasks in the main agent.
- Delegate substantial read-heavy investigation only when it materially improves efficiency, context quality, parallelism, or review quality. Use platform-specific roles defined in ORCHESTRATE.md.
- State assumptions explicitly. Ask when uncertainty materially affects requirements, correctness, scope, or authorization; continue independent work while awaiting clarification.
- If materially different interpretations exist, surface the tradeoffs and clarify the requirement. Use reasonable judgment for routine implementation details.
- If a simpler approach exists, say so. Push back when warranted.
- If missing information blocks safe progress, name the blocker and ask. Continue work that does not depend on the answer.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

For delegated changes, assign one writer per file set. The main agent must review the combined diff and validate integration before declaring completion.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```md
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Choose validation appropriate to the change. Add regression tests for behavior changes when useful; use configuration parsing, documentation checks, or targeted smoke checks for non-code changes. Do not omit required project checks.

When the same failure or underlying error recurs after an evidence-based correction, pause corrective retries while allowing useful evidence gathering, and request an independent assumption review using the platform-specific role in ORCHESTRATE.md. Continue only with a revised hypothesis and a concrete validation step; follow the retry budget in AGENT-POLICIES.md.

## 5. Git commit message rules

Based on the provided git diff, analyze the change and determine the main purpose or effect of the change. Use that as the subject line (first line) following the Conventional Commits format.
*Only* use one of: build:, ci:, chore:, docs:, feat:, fix:, perf:, refactor:, style:, test:
When a body is needed, leave a blank line after the subject and list the key implementation changes as bullet points (-).

Rules:

- Use English
- Keep the subject line under 80 characters
- Markdown formatting is allowed, but do not include code fences (like triple backticks) or explanations

Example output:
feat(component): add new validation to login form

- add error messages for empty input
- validate email format with regex
- update tests for invalid scenarios
