# Stateful Terminal Design

Date: 2026-04-01
Status: Draft for review
Scope: macOS-first desktop terminal with durable workspace memory

## Summary

Build a macOS terminal app whose core value is not multiplexing or agent orchestration, but remembering workspaces after terminals close.

The product behaves like a real terminal in one critical respect: closing a tab closes the process. It differs from a normal terminal in one critical respect: the app still remembers what that tab was, where it was, what it was connected to, and what the screen looked like near the end.

The top-level object is a user-defined workspace. A workspace is a task context, similar to a left-side tab in cmux. It can contain multiple terminal sessions, including a mix of local shells and SSH sessions. A workspace has one shared note. Sessions inside it can be closed and later manually recreated from stored metadata and screen snapshots.

## Goals

- Preserve workspace identity after tabs or windows close.
- Preserve enough session state that the user can recognize and manually reconstruct prior work.
- Support mixed local and SSH sessions inside the same workspace.
- Keep terminal behavior close to a real terminal: closing a session ends the process.
- Make manual recovery fast through structured session recipes.
- Prioritize macOS as the first shipping platform.
- Prefer Ghostty as the terminal engine direction where practical.

## Non-Goals

- Automatic process reattachment.
- Background daemon that keeps all shells alive after UI close.
- Multi-user sync.
- Built-in credential management for SSH keys or passwords.
- Heavy AI-specific workflow assumptions.
- Full workspace inference or automatic session grouping in v1.

## Product Model

### Workspace

A workspace is a user-created task grouping. It is not equal to a host, machine, or project root. A single workspace can contain:

- a local terminal in a project directory
- an SSH session on a remote host
- another local or remote tab related to the same task

Users explicitly add new tabs to the current workspace. The app does not auto-group sessions by host, path, or command in v1.

Each workspace stores:

- `id`
- `name`
- `note_body`
- `sort_order`
- `created_at`
- `updated_at`
- `last_opened_at`
- lightweight UI state such as selected tab and panel visibility

### Session

A session is one terminal process inside a workspace.

Each session stores:

- `id`
- `workspace_id`
- `transport` (`local` or `ssh`)
- `target_label` such as `local`, `prod`, or `lab`
- `shell`
- `title`
- `initial_cwd`
- `last_cwd`
- `state` (`live`, `closed`, `exited`, `lost`, `crashed`, `interrupted`)
- `started_at`
- `ended_at`
- `exit_status`
- `restore_recipe`

### Snapshot

A snapshot is a saved representation of a session near a meaningful point in time.

Each snapshot stores:

- `id`
- `session_id`
- `kind` (`checkpoint` or `final`)
- `captured_at`
- terminal dimensions: `cols`, `rows`
- `cwd`
- cursor position
- terminal screen contents and style information as a compressed structured blob

V1 should not store a plain bitmap screenshot as the canonical format. The canonical format should be a terminal grid representation that can be rendered like a screenshot while still allowing future search, copy, and structured inspection.

### Timeline Event

Timeline events are append-only records for workspace and session history.

Examples:

- `workspace_created`
- `workspace_opened`
- `session_started`
- `ssh_connected`
- `cwd_changed`
- `session_closed`
- `session_interrupted`
- `snapshot_finalized`
- `note_updated`

## UX Model

### App Entry

The app opens to a workspace-first view.

Workspace list items show:

- name
- recent activity
- count of live sessions
- count of recently closed sessions
- warning badge if interrupted sessions exist

### Workspace Detail

Opening a workspace shows three main regions:

- top or center area for live session tabs
- a recent closed sessions area with cards
- a persistent single note for the workspace

This screen must show live and recently closed sessions in the same context. The app should make it clear that a workspace persists even when its sessions do not.

### Recently Closed Session Card

Each card shows:

- transport and target, such as `local` or `ssh prod`
- last known cwd
- closure reason
- last activity time
- a preview rendered from the final or latest snapshot

Selecting the card opens a larger snapshot view plus recovery actions.

### Recovery Actions

Recovery is always manual in v1. The app creates a new session rather than reattaching to an old one.

Supported actions:

- `Open local shell here`
- `Reconnect SSH`
- `Reconnect SSH and cd here`
- `Copy last command`
- `Copy session recipe`

`restore_recipe` contains enough structured information to recreate the user’s setup without storing secrets.

### Note Model

Each workspace has exactly one note in v1. Notes are not session-scoped.

Use cases:

- next steps
- reminders
- questions to ask later
- small task context that outlives terminal processes

## Lifecycle and Snapshot Policy

### Close Behavior

Closing a session closes the process. This is intentional and should feel like a real terminal.

When the user closes a tab:

1. the terminal process is terminated
2. a final snapshot is written
3. the session state is updated with a close reason
4. the session moves into the workspace’s recently closed area

Closing the whole window follows the same rule for all live sessions in that window.

V1 should avoid heavy confirmation prompts. The product promise is not preventing closure, but making closure recoverable at the workspace-memory level.

### Checkpoint Triggers

Snapshots should be written at meaningful points, not every keystroke.

Recommended triggers:

- prompt returns and the screen is stable
- cwd changes
- SSH connect or disconnect events
- session focus changes
- tab close
- process exit
- short periodic checkpoint while state is dirty

This balances fidelity and performance while still giving high-confidence memory after crashes.

### Crash Behavior

If the app crashes, sessions without a normal finalization record are shown as `interrupted` on next launch. Their latest checkpoint remains available as the recovery surface.

The user can then start a new replacement session from the stored recipe.

## Architecture

### Recommended Approach

Use a split architecture:

- macOS host app in Swift/AppKit/SwiftUI
- Rust core for workspace memory, persistence, snapshot policy, and recovery logic
- terminal adapter layer that targets Ghostty first

This keeps the product’s durable state logic in Rust while respecting Ghostty’s current macOS-native reality.

### Ghostty-First Direction

Ghostty should be treated as the preferred terminal engine direction, not as the place to put all product state.

Implications:

- keep the app’s workspace and recovery model independent of Ghostty internals
- isolate Ghostty integration behind a terminal adapter interface
- allow fallback or replacement later if Ghostty embedding constraints change

Suggested internal interface:

- `TerminalSurface`
- `TerminalSessionController`
- `SnapshotExtractor`
- `ProcessLifecycleHooks`

The rest of the app should depend on these abstractions, not on Ghostty-specific types.

### Persistence

Use a single SQLite database under the app’s macOS Application Support directory.

Store:

- workspaces
- sessions
- snapshots
- timeline events
- UI state

Rationale:

- simple backup and migration
- transactional updates
- one place to inspect and debug user state
- enough performance for v1 scale

### SSH and Secrets

Do not store passwords or private keys.

Store only:

- target alias or host label
- username if available
- remote cwd
- shell or command context needed for restore recipes

Authentication remains delegated to existing SSH config, agent, or keychain systems.

### Error Handling

V1 should explicitly distinguish:

- user closed
- process exited normally
- SSH disconnected
- app crashed
- host app quit while session was live

These reasons should be visible in the UI and recorded in timeline events. The user should always understand whether they are looking at a cleanly closed session or an interrupted one.

## Testing Strategy

### Rust Core

Test:

- workspace CRUD
- session lifecycle transitions
- snapshot checkpoint policy
- restore recipe generation
- interrupted session recovery state

### Adapter Layer

Smoke test:

- live screen extraction
- final snapshot capture on close
- lifecycle event delivery

### macOS Host

Smoke test:

- app relaunch restores workspace list
- workspace note persists
- recently closed sessions appear after close
- interrupted sessions are marked correctly after abnormal termination

## V1 Boundaries

Include:

- local sessions
- SSH sessions
- workspace-scoped note
- recently closed session history
- manual recovery actions
- snapshot previews

Exclude:

- automatic reattach
- background keepalive daemon
- multi-user collaboration
- secrets vault
- automatic workspace grouping
- deep command history analytics

## Open Source and Dependency Notes

As of 2026-04-01, Ghostty officially supports macOS and Linux, with Windows planned for the future. Official docs also describe Ghostty as having a native macOS app written in Swift and a shared `libghostty` core, while cautioning that the standalone library API is not yet considered stable. This strongly supports a design where Ghostty is the preferred engine target but not the owner of workspace-memory state.

References:

- https://ghostty.org/docs/about
- https://ghostty.org/docs/linux
- https://github.com/ghostty-org/ghostty

## Initial Implementation Order

1. Define Rust data model and SQLite schema for workspaces, sessions, snapshots, and timeline events.
2. Build a minimal macOS host shell with workspace list, workspace detail, and note panel.
3. Integrate a terminal adapter layer with a single live terminal surface.
4. Persist session lifecycle and final snapshots on close.
5. Add recently closed cards and manual recovery actions.
6. Add interrupted session handling on relaunch.

## Decision Summary

- Platform: macOS first
- Product type: general-purpose terminal
- Core unit: user-defined workspace
- Session grouping: explicit by user
- Close behavior: closing a tab ends the process
- Recovery type: manual only in v1
- Memory surface: metadata plus terminal screen snapshot
- Notes: one note per workspace
- Engine direction: Ghostty first, behind an adapter
- State owner: app-level workspace memory, not the terminal engine
