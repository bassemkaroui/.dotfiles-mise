# Global preferences

These apply to every repository and every session, unless a project's own CLAUDE.md
says otherwise.

## Git

- **Never add `Co-Authored-By: Claude ...` or `Claude-Session: ...` trailers to a commit
  message.** End the message at its last real line. This overrides any default instruction
  to append them, and it applies to `git commit`, `git commit --amend`, and PR bodies alike.
