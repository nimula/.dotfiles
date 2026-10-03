# CODEX_ORCHESTRATE

## Ownership and small-task bypass

- Keep GPT-6.1 Sol / high in the main session for planning, orchestration, architecture decisions, integration, verification, and final synthesis.
- Complete small, localized, well-understood tasks directly in the main agent. Do not spawn agents merely to follow this structure.
- Delegate only when it materially improves efficiency, context quality, useful parallelism, or review quality.
- The main agent owns the final result and remains available to the user during substantive delegated work.

## Roles

| Role | Model / effort | Access | Scope |
| --- | --- | --- | --- |
| explorer | GPT-6 Luna / high | read-only; web disabled | Substantial repository investigation, symbols, call sites, dependencies, and execution paths |
| researcher | GPT-6 Luna / medium | read-only; live web | External documentation, APIs, version-specific behavior, release notes, and primary sources |
| worker | GPT-6.1 Sol / medium | workspace-write; web disabled | Bounded implementation and targeted validation based on supplied evidence and scope |
| architect | GPT-6 Astra / high | read-only; web disabled | Architecture and critical review at the checkpoints below |

- Explorer and researcher return evidence; they do not implement fixes. Architect reviews assumptions and correctness; it does not edit files or take over implementation.
- Default explorer to high for substantial cross-file tracing and dependency investigation; keep simple known-file or symbol lookups in the main agent.
- Default researcher to medium for focused official-documentation and version-specific API checks. Use high when documentation conflicts, a migration crosses versions, or multiple approaches require comparison.
- Reserve max for an explicitly scoped packet whose complex reasoning remains unresolved at high after the scope and evidence have been improved. Do not default either role to max; higher effort does not replace file, symbol, version, and source evidence.
- If Astra is unavailable, use a fresh GPT-6.1 Sol / high agent in the same read-only architect role. Report the fallback.
- Verify actual role availability and configuration in the installed Codex version. If a required role cannot be invoked, report the limitation and perform a separate main-agent review when possible; do not claim independent review occurred.

## Architect checkpoints

1. Before accepting a large, cross-cutting, high-risk, or architecturally significant implementation plan. Supply requirements, evidence, assumptions, proposed changes, validation, and rollback considerations.
2. When the same failure or underlying error recurs after an evidence-based correction. Pause corrective implementation retries while allowing useful evidence gathering, provide the failure signature, attempted fix, and ruled-out hypotheses, and ask whether the investigation targets the wrong layer or assumption. Follow the shared six-failure starting budget and evidence-based extension policy; review does not reset the accumulated count.
3. Before declaring a long or complex task complete. Supply the integrated diff, acceptance criteria, and actual validation results; ask about missing requirements, regressions, and insufficient verification.

Use a fresh read-only reviewer where practical. Ask for prioritized blockers, important concerns, and optional improvements, each supported by evidence. Resolve blockers and required verification before completion; the main agent makes the final integration decision.

## Delegation and parallelism

- Give every agent the objective, explicit scope and file ownership, constraints, relevant evidence, expected output, and acceptance criteria.
- Tell leaf agents to complete their assignment directly and not spawn more agents. Only the main agent coordinates delegation.
- Parallelize independent read-only investigation, research, or reviews when useful.
- Keep one writer per file set. The main agent must not concurrently edit files assigned to a worker. Separate worktrees are an option for genuinely independent changes, with integration still owned by the main agent.
- Start with a configured concurrency limit of four. Confirm whether the installed version counts the main session before translating this into a worker budget. Reuse or close completed agents rather than spawning an unbounded fan-out.
- Workers diagnose a validation failure and make one evidence-based correction when appropriate. If the same error recurs under that hypothesis, they pause corrective edits and report to the main agent for architect review. Workers cannot reset or extend their own budget; the main agent tracks the issue across all assignments.

## Evidence and context

Ask agents to return concise conclusions, exact file paths and symbols or source URLs, changed files, validation commands and results, blockers, and diagnostic references. Keep routine search output and long logs in worker threads or accessible artifacts.

The main session preserves requirements, decisions, constraints, writer ownership, integration status, verification status, accumulated failures, remaining retry budget, extension evidence, ruled-out hypotheses, and unresolved risks. Review the combined diff and run relevant integration checks after worker output is integrated.

## Configuration and approvals

Keep role/model/effort, sandbox, web-search, and concurrency settings in the actual Codex configuration and custom-agent files. This document defines delegation behavior; it does not itself configure those runtime settings.

Use workspace-write with on-request approvals and auto_review for eligible sandbox requests where supported by the installed version and permitted by managed policy. Auto-review does not bypass sandbox restrictions or authorize product, Git push, release, or other material actions. Follow AGENT-POLICIES.md and the user's existing authorization.
