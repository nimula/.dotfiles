# AGENT-POLICIES.md

## Communication and Code Style

- All user-facing responses must use Traditional Chinese. NEVER use Simplified Chinese. This rule applies to “thinking” as well as all narrative text written by you for users to read, regardless of the output channel.
- The only exception is “technical literal content” itself: code, commit messages, file paths, log/CLI output, and deliverables required by existing project conventions to retain their original language—these should remain in their original language because they are the deliverables themselves, not responses to users.
- Lead with the result and its impact, then provide only the technical detail needed.

## Safety Rails

Ask for confirmation before pushing to Git

## When Blocked

- If tests fail after 3 attempts: stop and report the failing test with full output
- If you encounter merge conflicts: stop and show the conflicting files
- Never: delete files to resolve errors, force push, or skip tests

## NEVER

- Read or modify `.env*`, or CI secrets without explicit approval
- Remove feature flags without searching all call sites
- Commit without running tests

## Compact Instructions

When compressing, preserve in priority order:

1. Architecture decisions (NEVER summarize)
2. Modified files and their key changes
3. Current verification status (pass/fail)
4. Open TODOs and rollback notes
5. Tool outputs (can delete, keep pass/fail only)
