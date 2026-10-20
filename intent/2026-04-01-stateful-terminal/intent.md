# Intent: Stateful Terminal

- Date: 2026-04-01
- Status: retroactive — spec.md/plan.md에서 2026-10-20 재구성
- Next: spec.md

## Problem
In a normal terminal, closing a tab ends the process and the work is gone: the app no longer knows what that tab was, where it was, what it was connected to, or what the screen looked like. Users have to rebuild prior work from memory.

## Proposed outcome
- A macOS terminal whose core value is remembering projects after terminals close.
- A project is a user-defined task context holding a mix of local and SSH sessions, plus one shared note.
- Closing a tab still ends the process, but the app keeps its metadata and a near-final screen snapshot.
- Recently closed sessions appear as cards; the user recognizes them and recreates them manually and quickly (open shell here, reconnect SSH and cd here, copy last command or recipe).
- After a crash, unfinished sessions show as `interrupted` with their latest checkpoint.
- The UI always tells cleanly closed sessions from interrupted ones (user closed, exited, SSH disconnected, app crashed, app quit).

## Affected users and systems
- Developers who work across several local and SSH terminals per task.
- macOS host app, project-memory persistence, terminal engine (Ghostty).

## Constraints
- macOS first. Ghostty is the preferred engine but must not own project-memory state; keep it replaceable.
- Terminal behavior stays close to a real terminal: closing a session ends the process, without heavy confirmation prompts.
- Never store SSH passwords or private keys; authentication stays with existing SSH config/agent/keychain.
- Snapshots are taken at meaningful points, not every keystroke.

## Out of scope
- Automatic process reattachment, background daemon keeping shells alive.
- Multi-user sync/collaboration, credential vault.
- Automatic project grouping or inference, heavy AI-specific workflows, deep command history analytics.

## Open questions
- Ghostty's standalone library API is not yet considered stable (as of 2026-04-01).
