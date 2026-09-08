# CLAUDE_ORCHESTRATE

## Orchestration workflow

- Keep Fable or Opus in the primary task for planning, architecture, judgment, conflict resolution, verification, and final synthesis.
- Use fast-worker subagents for clear, bounded, repeatable, or high-volume packets with explicit success criteria.
- Use deep-reasoner subagents when implementation needs more context, judgment, or risk management.
- Start fast-worker at XHigh for efficiency. Use Max for difficult or fully specified implementation packets that benefit from deeper work.
- Give every worker explicit scope, constraints, expected output, and done evidence.
- Keep the coordinator available to the user while substantive work runs elsewhere.
- Tell leaf workers to complete their assignment directly and not spawn more agents.
- Keep product, permission, release, and other material approvals with the user.
- Keep one writer per file set. Use fresh, read-only agents for independent review.
