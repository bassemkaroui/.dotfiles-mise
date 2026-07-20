---
name: "custom-init"
description: "Analyze this codebase and create a CLAUDE.md file with codebase documentation"
model: haiku
---

## Your task:

Analyze this codebase with the "Explore" builtin agent and then create a CLAUDE.md file following these principles:

1. Keep it under 150 lines total - focus only on universally applicable information
2. Cover the essentials: WHAT (tech stack, project structure), WHY (purpose), and HOW (build/test commands)
3. Use Progressive Disclosure: instead of including all instructions, create a brief index pointing to other markdown files in .claude/docs/ for specialized topics
4. For concrete code pointers, prefer **stable references**:
    - `file + symbol` (e.g., `src/auth/service.py (AuthService.login)`)
    - `file + responsibility` (e.g., `src/auth/service.py — user authentication flow`)
    - `file + test name` when describing behavior
5. Avoid line numbers unless absolutely necessary; do not rely on them for navigation.
6. Assume I'll use linters for code style - don't include formatting guidelines

Structure it as: project overview, tech stack, key directories/their purposes, essential build/test commands, and a list of additional documentation files Claude should check when relevant.

Additionally, extract patterns you observe into separate files:

- .claude/docs/architectural_patterns.md - document the architectural patterns, design decisions, and conventions used (e.g., dependency injection, state management, API design patterns). Make sure these are patterns that appear in multiple files.

Reference these files in the CLAUDE.md's "Additional Documentation" section.

### Discovery scope (git worktrees)

- Treat the current working directory as the root of the codebase.
- Do not read or infer information from parent directories or sibling git worktrees.
- If multiple git worktrees are detected, ignore all except the one containing the current working directory.
- If unsure which files belong to the active worktree, ask before proceeding.
