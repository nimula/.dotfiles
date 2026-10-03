# AGENT-POLICIES.md

## Communication and Code Style

- All user-facing responses must use Traditional Chinese. NEVER use Simplified Chinese. This rule applies to “thinking” as well as all narrative text written by you for users to read, regardless of the output channel.
- The only exception is “technical literal content” itself: code, commit messages, file paths, log/CLI output, and deliverables required by existing project conventions to retain their original language—these should remain in their original language because they are the deliverables themselves, not responses to users.
- Lead with the result and its impact, then provide only the technical detail needed.

## Safety Rails

- Obtain explicit user authorization before pushing to Git. An earlier authorization covering the same action and scope remains valid.
- Obtain explicit user authorization before downloading, installing, or upgrading additional tools, or adding tool dependencies, including tools used only for testing or placed in temporary directories. Explain the purpose, acquisition method, location, maintenance and platform costs, and available alternatives first. General implementation or validation authorization does not authorize additional tools. If a required tool is unavailable, report the limitation and continue independent work using existing tools.
- Product, scope, release, and other material approvals remain with the user. A subagent review does not grant authorization.
- Platform approval mechanisms govern eligible tool and sandbox approvals only; they do not replace user authorization for material actions or override these policies.
- All delegated agents must follow the same applicable communication, secret-handling, and verification policies. Read-only roles must not edit files or perform implementation work.

## When Blocked

- When the same failure or underlying error recurs after an evidence-based correction under the same hypothesis, workers pause corrective edits and report to the main agent. The main agent requests an independent assumption review before further corrections; use the role specified in ORCHESTRATE.md. Evidence gathering may continue within existing authorization while corrective retries are paused.
- Start with a budget of six failed validation runs for the same unresolved issue, including the initial failure. Each corrective retry must be supported by new evidence or an explicit hypothesis; after repeated-failure review, require a revised hypothesis and a concrete validation step. Delegation, reviewer changes, new worker assignments, and compaction do not reset the accumulated count.
- When the initial budget is exhausted, the main agent assesses actual progress. If new root-cause evidence supports a concrete next step, it may grant one bounded extension of up to two additional failed validation runs. Record the evidence, revised hypothesis, extension size, and stop condition before continuing. Six is the starting budget, not an unconditional stop; extensions remain finite and never reset prior failures.
- If no supported next step exists, no new root-cause evidence justifies an extension, or the extension is exhausted, stop corrective retries for that issue and report the failing command, relevant error, attempted corrections, and remaining blocker. Continue independent authorized work and useful evidence gathering when possible. Do not claim the unresolved issue is fixed.
- Keep full diagnostic output in a local artifact or worker thread; return concise evidence and a reference to the main agent and user. Redact secrets before retaining or sharing output.
- If you encounter merge conflicts: stop and show the conflicting files
- Never: delete files to resolve errors, force push, or skip tests

## NEVER

- Read or modify `.env*`, or CI secrets without explicit approval
- Remove feature flags without searching all call sites
- Commit without completing validation appropriate to the change and all required project checks. Report unavailable checks explicitly; do not claim verification or completion when required validation remains blocked.

## Compact Instructions

When compressing, preserve in priority order:

1. User requirements, acceptance criteria, scope, constraints, and authorization boundaries
2. Architecture decisions (preserve the exact decision; retain rationale and rejected alternatives concisely)
3. Modified files, writer ownership, and current integration state
4. Verification commands and status (pass/fail/not run), failure signature, ruled-out hypotheses, current hypothesis, accumulated failed-run count, remaining budget, and any granted extension
5. Open TODOs, blockers, and rollback notes
6. Evidence references; omit routine raw tool output when an accessible diagnostic reference and concise result suffice
