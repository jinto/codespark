# Stateful Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS-first terminal app that remembers user-defined workspaces, persists closed-session metadata plus terminal snapshots, and supports manual recovery without keeping processes alive after close.

**Architecture:** Use a split architecture with a Rust core for persistence, lifecycle state, snapshots, restore recipes, and timeline events; a thin Rust-to-Swift bridge for the macOS app; and a SwiftUI/AppKit host shell that owns the workspace-first UI and terminal surface integration. Keep terminal integration behind a `TerminalHostProtocol`, with Ghostty as the preferred adapter but never the owner of workspace-memory state.

**Tech Stack:** Rust 1.88+, `rusqlite`, `serde`, `serde_json`, `time`, `uuid`, `zstd`, `uniffi`; Swift 5.10+, SwiftUI, AppKit, XCTest; XcodeGen for the macOS project; Ghostty-backed adapter behind a factory and feature gate.

---

## Execution Preconditions

- This exact `spark3` directory is not currently a git repository. Before Task 1, initialize one with `git init`.
- Install local tools before starting:
  - `cargo`
  - `rustup component add rustfmt clippy`
  - `cargo install uniffi_bindgen`
  - `brew install xcodegen`
- Run all commands from the repository root once initialized.

## File Structure

### Root

- Create: `Cargo.toml`
- Create: `rust-toolchain.toml`
- Create: `.gitignore`
- Create: `scripts/generate-swift-bindings.sh`
- Create: `scripts/build-macos.sh`

### Rust core

- Create: `crates/workspace-core/Cargo.toml`
- Create: `crates/workspace-core/src/lib.rs`
- Create: `crates/workspace-core/src/models.rs`
- Create: `crates/workspace-core/src/store.rs`
- Create: `crates/workspace-core/src/snapshot.rs`
- Create: `crates/workspace-core/src/restore.rs`
- Create: `crates/workspace-core/src/timeline.rs`
- Test: `crates/workspace-core/tests/workspace_store.rs`
- Test: `crates/workspace-core/tests/session_lifecycle.rs`
- Test: `crates/workspace-core/tests/snapshot_restore.rs`
- Test: `crates/workspace-core/tests/interrupted_recovery.rs`

### Rust bridge

- Create: `crates/workspace-ffi/Cargo.toml`
- Create: `crates/workspace-ffi/build.rs`
- Create: `crates/workspace-ffi/src/lib.rs`
- Create: `crates/workspace-ffi/src/api.udl`
- Test: `crates/workspace-ffi/tests/service_smoke.rs`

### macOS app

- Create: `apps/macos/project.yml`
- Create: `apps/macos/StatefulTerminal/App/StatefulTerminalApp.swift`
- Create: `apps/macos/StatefulTerminal/App/AppDelegate.swift`
- Create: `apps/macos/StatefulTerminal/Bridge/WorkspaceCoreClient.swift`
- Create: `apps/macos/StatefulTerminal/Bridge/StatefulTerminal-Bridging-Header.h`
- Create: `apps/macos/StatefulTerminal/Models/AppModel.swift`
- Create: `apps/macos/StatefulTerminal/Models/WorkspaceViewData.swift`
- Create: `apps/macos/StatefulTerminal/Views/WorkspaceListView.swift`
- Create: `apps/macos/StatefulTerminal/Views/WorkspaceDetailView.swift`
- Create: `apps/macos/StatefulTerminal/Views/WorkspaceNoteView.swift`
- Create: `apps/macos/StatefulTerminal/Views/RecentlyClosedSessionCardView.swift`
- Create: `apps/macos/StatefulTerminal/Views/ClosedSessionInspectorView.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/TerminalHostProtocol.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/MockTerminalHost.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/TerminalHostFactory.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/GhosttyTerminalHost.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/TerminalSurfaceHostView.swift`
- Test: `apps/macos/StatefulTerminalTests/AppModelTests.swift`
- Test: `apps/macos/StatefulTerminalTests/WorkspaceFlowTests.swift`
- Test: `apps/macos/StatefulTerminalTests/RecoveryActionsTests.swift`
- Test: `apps/macos/StatefulTerminalTests/TerminalHostFactoryTests.swift`

## Task 1: Bootstrap the Rust workspace and workspace-store foundation

**Files:**
- Create: `Cargo.toml`
- Create: `rust-toolchain.toml`
- Create: `.gitignore`
- Create: `crates/workspace-core/Cargo.toml`
- Create: `crates/workspace-core/src/lib.rs`
- Create: `crates/workspace-core/src/models.rs`
- Create: `crates/workspace-core/src/store.rs`
- Test: `crates/workspace-core/tests/workspace_store.rs`

- [ ] **Step 1: Write the failing workspace-store test**

```rust
// crates/workspace-core/tests/workspace_store.rs
use workspace_core::Store;

#[test]
fn creates_and_lists_workspaces_in_recent_order() {
    let store = Store::open(":memory:").unwrap();
    store.create_workspace("spark3").unwrap();
    store.create_workspace("release").unwrap();

    let summaries = store.list_workspace_summaries().unwrap();
    let names: Vec<_> = summaries.iter().map(|item| item.name.as_str()).collect();

    assert_eq!(names, vec!["release", "spark3"]);
    assert_eq!(summaries[0].live_sessions, 0);
    assert_eq!(summaries[0].recently_closed_sessions, 0);
    assert!(!summaries[0].has_interrupted_sessions);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `git init && cargo test -p workspace-core --test workspace_store -v`  
Expected: FAIL with `could not find Cargo.toml` or `package ID specification 'workspace-core' did not match any packages`

- [ ] **Step 3: Write the minimal workspace store implementation**

```toml
# Cargo.toml
[workspace]
members = ["crates/workspace-core"]
resolver = "2"
```

```toml
# rust-toolchain.toml
[toolchain]
channel = "1.88.0"
components = ["rustfmt", "clippy"]
```

```gitignore
# .gitignore
/target
/.build
/DerivedData
/.swiftpm
/apps/macos/StatefulTerminal.xcodeproj
```

```toml
# crates/workspace-core/Cargo.toml
[package]
name = "workspace-core"
version = "0.1.0"
edition = "2021"

[dependencies]
rusqlite = { version = "0.32", features = ["bundled"] }
serde = { version = "1", features = ["derive"] }
time = { version = "0.3", features = ["formatting", "macros", "parsing"] }
uuid = { version = "1", features = ["v4", "serde"] }
```

```rust
// crates/workspace-core/src/lib.rs
mod models;
mod store;

pub use models::WorkspaceSummary;
pub use store::Store;
```

```rust
// crates/workspace-core/src/models.rs
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub live_sessions: i64,
    pub recently_closed_sessions: i64,
    pub has_interrupted_sessions: bool,
    pub updated_at: i64,
}
```

```rust
// crates/workspace-core/src/store.rs
use rusqlite::{params, Connection};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::WorkspaceSummary;

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn create_workspace(&self, name: &str) -> rusqlite::Result<String> {
        let id = Uuid::new_v4().to_string();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        self.conn.execute(
            "insert into workspaces (id, name, note_body, updated_at, last_opened_at)
             values (?1, ?2, '', ?3, ?3)",
            params![id, name, now],
        )?;
        Ok(id)
    }

    pub fn list_workspace_summaries(&self) -> rusqlite::Result<Vec<WorkspaceSummary>> {
        let mut stmt = self.conn.prepare(
            "select id, name, updated_at from workspaces order by updated_at desc, rowid desc",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(WorkspaceSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                live_sessions: 0,
                recently_closed_sessions: 0,
                has_interrupted_sessions: false,
                updated_at: row.get(2)?,
            })
        })?;
        rows.collect()
    }

    fn migrate(&self) -> rusqlite::Result<()> {
        self.conn.execute_batch(
            "create table if not exists workspaces (
                id text primary key,
                name text not null,
                note_body text not null,
                updated_at integer not null,
                last_opened_at integer not null
            );",
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p workspace-core --test workspace_store -v`  
Expected: PASS with `test creates_and_lists_workspaces_in_recent_order ... ok`

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml rust-toolchain.toml .gitignore crates/workspace-core
git commit -m "feat: bootstrap workspace core store"
```

## Task 2: Add sessions, workspace notes, and workspace-detail queries

**Files:**
- Modify: `crates/workspace-core/src/lib.rs`
- Modify: `crates/workspace-core/src/models.rs`
- Modify: `crates/workspace-core/src/store.rs`
- Test: `crates/workspace-core/tests/session_lifecycle.rs`

- [ ] **Step 1: Write the failing session-lifecycle test**

```rust
// crates/workspace-core/tests/session_lifecycle.rs
use workspace_core::{CloseReason, NewSession, SessionTransport, Store};

#[test]
fn closing_a_session_moves_it_to_recently_closed_and_persists_the_workspace_note() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("release").unwrap();

    store.update_workspace_note(&workspace_id, "check prod logs").unwrap();
    let session_id = store.start_session(NewSession {
        workspace_id: workspace_id.clone(),
        transport: SessionTransport::Ssh,
        target_label: "prod".into(),
        title: "prod logs".into(),
        shell: "zsh".into(),
        initial_cwd: Some("/srv/app".into()),
    }).unwrap();

    store.close_session(&session_id, CloseReason::UserClosed, Some("/srv/app".into()), None).unwrap();

    let detail = store.workspace_detail(&workspace_id).unwrap();
    assert_eq!(detail.note_body, "check prod logs");
    assert_eq!(detail.live_sessions.len(), 0);
    assert_eq!(detail.closed_sessions.len(), 1);
    assert_eq!(detail.closed_sessions[0].title, "prod logs");
    assert_eq!(detail.closed_sessions[0].close_reason, CloseReason::UserClosed);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p workspace-core --test session_lifecycle -v`  
Expected: FAIL with missing items such as `NewSession`, `start_session`, `close_session`, or `workspace_detail`

- [ ] **Step 3: Write the minimal session and note implementation**

```rust
// crates/workspace-core/src/models.rs
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionTransport {
    Local,
    Ssh,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Live,
    Closed,
    Exited,
    Lost,
    Crashed,
    Interrupted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseReason {
    UserClosed,
    ProcessExited,
    SshDisconnected,
    AppCrashed,
    HostQuit,
}

#[derive(Debug, Clone)]
pub struct NewSession {
    pub workspace_id: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub title: String,
    pub shell: String,
    pub initial_cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub last_cwd: Option<String>,
    pub close_reason: CloseReason,
}

#[derive(Debug, Clone)]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub note_body: String,
    pub live_sessions: Vec<SessionSummary>,
    pub closed_sessions: Vec<SessionSummary>,
}
```

```rust
// crates/workspace-core/src/lib.rs
mod models;
mod store;

pub use models::{
    CloseReason, NewSession, SessionState, SessionSummary, SessionTransport, WorkspaceDetail,
    WorkspaceSummary,
};
pub use store::Store;
```

```rust
// crates/workspace-core/src/store.rs
use crate::{
    CloseReason, NewSession, SessionSummary, SessionTransport, WorkspaceDetail, WorkspaceSummary,
};

pub fn encode_transport(value: SessionTransport) -> &'static str {
    match value {
        SessionTransport::Local => "local",
        SessionTransport::Ssh => "ssh",
    }
}

pub fn encode_close_reason(value: CloseReason) -> &'static str {
    match value {
        CloseReason::UserClosed => "user_closed",
        CloseReason::ProcessExited => "process_exited",
        CloseReason::SshDisconnected => "ssh_disconnected",
        CloseReason::AppCrashed => "app_crashed",
        CloseReason::HostQuit => "host_quit",
    }
}

impl Store {
    pub fn update_workspace_note(&self, workspace_id: &str, note_body: &str) -> rusqlite::Result<()> {
        let now = OffsetDateTime::now_utc().unix_timestamp();
        self.conn.execute(
            "update workspaces set note_body = ?2, updated_at = ?3 where id = ?1",
            params![workspace_id, note_body, now],
        )?;
        Ok(())
    }

    pub fn start_session(&self, input: NewSession) -> rusqlite::Result<String> {
        let id = Uuid::new_v4().to_string();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        self.conn.execute(
            "insert into sessions (
                id, workspace_id, transport, target_label, title, shell, initial_cwd, last_cwd,
                state, close_reason, started_at, ended_at, updated_at
            ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, 'live', null, ?8, null, ?8)",
            params![
                id,
                input.workspace_id,
                encode_transport(input.transport),
                input.target_label,
                input.title,
                input.shell,
                input.initial_cwd,
                now,
            ],
        )?;
        Ok(id)
    }

    pub fn close_session(
        &self,
        session_id: &str,
        reason: CloseReason,
        last_cwd: Option<String>,
        exit_status: Option<i64>,
    ) -> rusqlite::Result<()> {
        let now = OffsetDateTime::now_utc().unix_timestamp();
        self.conn.execute(
            "update sessions
             set state = 'closed',
                 close_reason = ?2,
                 last_cwd = coalesce(?3, last_cwd),
                 exit_status = ?4,
                 ended_at = ?5,
                 updated_at = ?5
             where id = ?1",
            params![session_id, encode_close_reason(reason), last_cwd, exit_status, now],
        )?;
        Ok(())
    }

    pub fn workspace_detail(&self, workspace_id: &str) -> rusqlite::Result<WorkspaceDetail> {
        let mut detail = self.conn.query_row(
            "select id, name, note_body from workspaces where id = ?1",
            params![workspace_id],
            |row| {
                Ok(WorkspaceDetail {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    note_body: row.get(2)?,
                    live_sessions: Vec::new(),
                    closed_sessions: Vec::new(),
                })
            },
        )?;

        let mut stmt = self.conn.prepare(
            "select id, title, transport, target_label, last_cwd, close_reason, state
             from sessions where workspace_id = ?1 order by updated_at desc",
        )?;
        let rows = stmt.query_map(params![workspace_id], |row| {
            let state: String = row.get(6)?;
            Ok((state, SessionSummary {
                id: row.get(0)?,
                title: row.get(1)?,
                transport: match row.get::<_, String>(2)?.as_str() {
                    "ssh" => SessionTransport::Ssh,
                    _ => SessionTransport::Local,
                },
                target_label: row.get(3)?,
                last_cwd: row.get(4)?,
                close_reason: match row.get::<_, Option<String>>(5)?.as_deref() {
                    Some("process_exited") => CloseReason::ProcessExited,
                    Some("ssh_disconnected") => CloseReason::SshDisconnected,
                    Some("app_crashed") => CloseReason::AppCrashed,
                    Some("host_quit") => CloseReason::HostQuit,
                    _ => CloseReason::UserClosed,
                },
            }))
        })?;

        for item in rows {
            let (state, session) = item?;
            if state == "live" {
                detail.live_sessions.push(session);
            } else {
                detail.closed_sessions.push(session);
            }
        }

        Ok(detail)
    }

    fn migrate(&self) -> rusqlite::Result<()> {
        self.conn.execute_batch(
            "create table if not exists workspaces (
                id text primary key,
                name text not null,
                note_body text not null,
                updated_at integer not null,
                last_opened_at integer not null
            );
            create table if not exists sessions (
                id text primary key,
                workspace_id text not null,
                transport text not null,
                target_label text not null,
                title text not null,
                shell text not null,
                initial_cwd text,
                last_cwd text,
                state text not null,
                close_reason text,
                exit_status integer,
                started_at integer not null,
                ended_at integer,
                updated_at integer not null
            );",
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p workspace-core --test workspace_store --test session_lifecycle -v`  
Expected: PASS with both tests ending in `... ok`

- [ ] **Step 5: Commit**

```bash
git add crates/workspace-core
git commit -m "feat: add session lifecycle and workspace detail queries"
```

## Task 3: Persist snapshots, restore recipes, timeline events, and interrupted-session recovery

**Files:**
- Modify: `crates/workspace-core/Cargo.toml`
- Create: `crates/workspace-core/src/snapshot.rs`
- Create: `crates/workspace-core/src/restore.rs`
- Create: `crates/workspace-core/src/timeline.rs`
- Modify: `crates/workspace-core/src/lib.rs`
- Modify: `crates/workspace-core/src/models.rs`
- Modify: `crates/workspace-core/src/store.rs`
- Test: `crates/workspace-core/tests/snapshot_restore.rs`
- Test: `crates/workspace-core/tests/interrupted_recovery.rs`

- [ ] **Step 1: Write the failing snapshot and interruption tests**

```rust
// crates/workspace-core/tests/snapshot_restore.rs
use workspace_core::{
    CloseReason, NewSession, NewSnapshot, SessionTransport, SnapshotKind, Store, TerminalGrid,
};

#[test]
fn final_snapshot_and_restore_recipe_are_available_for_a_closed_ssh_session() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("release").unwrap();
    let session_id = store.start_session(NewSession {
        workspace_id: workspace_id.clone(),
        transport: SessionTransport::Ssh,
        target_label: "prod".into(),
        title: "prod logs".into(),
        shell: "zsh".into(),
        initial_cwd: Some("/srv/app".into()),
    }).unwrap();

    store.record_snapshot(NewSnapshot {
        session_id: session_id.clone(),
        kind: SnapshotKind::Final,
        cwd: Some("/srv/app".into()),
        grid: TerminalGrid::from_lines(80, 24, &["tail -f log", "error line"]),
    }).unwrap();
    store.close_session(&session_id, CloseReason::UserClosed, Some("/srv/app".into()), None).unwrap();

    let detail = store.workspace_detail(&workspace_id).unwrap();
    assert_eq!(detail.closed_sessions[0].snapshot_preview.lines[1], "error line");
    assert_eq!(
        detail.closed_sessions[0].restore_recipe.launch_command,
        "ssh prod -- 'cd /srv/app && exec zsh -l'"
    );
}
```

```rust
// crates/workspace-core/tests/interrupted_recovery.rs
use workspace_core::{NewSession, SessionTransport, Store};

#[test]
fn unfinalized_live_sessions_are_marked_interrupted_on_next_launch() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("spark3").unwrap();
    store.start_session(NewSession {
        workspace_id: workspace_id.clone(),
        transport: SessionTransport::Local,
        target_label: "local".into(),
        title: "shell".into(),
        shell: "zsh".into(),
        initial_cwd: Some("/Users/jinto/projects/spark3".into()),
    }).unwrap();

    store.reconcile_interrupted_sessions().unwrap();

    let summaries = store.list_workspace_summaries().unwrap();
    assert!(summaries[0].has_interrupted_sessions);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p workspace-core --test snapshot_restore --test interrupted_recovery -v`  
Expected: FAIL with missing items such as `NewSnapshot`, `SnapshotKind`, `TerminalGrid`, `record_snapshot`, or `reconcile_interrupted_sessions`

- [ ] **Step 3: Write the minimal snapshot, recipe, and interruption implementation**

```rust
// crates/workspace-core/src/snapshot.rs
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TerminalGrid {
    pub cols: u16,
    pub rows: u16,
    pub lines: Vec<String>,
}

impl TerminalGrid {
    pub fn from_lines(cols: u16, rows: u16, lines: &[&str]) -> Self {
        Self {
            cols,
            rows,
            lines: lines.iter().map(|item| item.to_string()).collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotKind {
    Checkpoint,
    Final,
}

#[derive(Debug, Clone)]
pub struct NewSnapshot {
    pub session_id: String,
    pub kind: SnapshotKind,
    pub cwd: Option<String>,
    pub grid: TerminalGrid,
}
```

```toml
# crates/workspace-core/Cargo.toml
[dependencies]
rusqlite = { version = "0.32", features = ["bundled"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
time = { version = "0.3", features = ["formatting", "macros", "parsing"] }
uuid = { version = "1", features = ["v4", "serde"] }
zstd = "0.13"
```

```rust
// crates/workspace-core/src/restore.rs
use crate::SessionTransport;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreRecipe {
    pub launch_command: String,
}

pub fn build_restore_recipe(
    transport: SessionTransport,
    target_label: &str,
    shell: &str,
    cwd: Option<&str>,
) -> RestoreRecipe {
    let launch_command = match transport {
        SessionTransport::Local => match cwd {
            Some(path) => format!("{shell} -lc 'cd {path} && exec {shell} -l'"),
            None => format!("{shell} -l"),
        },
        SessionTransport::Ssh => match cwd {
            Some(path) => format!("ssh {target_label} -- 'cd {path} && exec {shell} -l'"),
            None => format!("ssh {target_label}"),
        },
    };

    RestoreRecipe { launch_command }
}
```

```rust
// crates/workspace-core/src/timeline.rs
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TimelineEventKind {
    WorkspaceCreated,
    SessionStarted,
    SnapshotFinalized,
    SessionClosed,
    SessionInterrupted,
    NoteUpdated,
}
```

```rust
// crates/workspace-core/src/models.rs
use crate::{RestoreRecipe, TerminalGrid};

#[derive(Debug, Clone)]
pub struct ClosedSessionSummary {
    pub id: String,
    pub title: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub last_cwd: Option<String>,
    pub close_reason: CloseReason,
    pub snapshot_preview: TerminalGrid,
    pub restore_recipe: RestoreRecipe,
}

#[derive(Debug, Clone)]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub note_body: String,
    pub live_sessions: Vec<SessionSummary>,
    pub closed_sessions: Vec<ClosedSessionSummary>,
}
```

```rust
// crates/workspace-core/src/lib.rs
mod models;
mod restore;
mod snapshot;
mod store;
mod timeline;

pub use models::{
    CloseReason, ClosedSessionSummary, NewSession, SessionState, SessionSummary, SessionTransport,
    WorkspaceDetail, WorkspaceSummary,
};
pub use restore::{build_restore_recipe, RestoreRecipe};
pub use snapshot::{NewSnapshot, SnapshotKind, TerminalGrid};
pub use store::Store;
```

```rust
// crates/workspace-core/src/store.rs
use crate::{
    build_restore_recipe, CloseReason, ClosedSessionSummary, NewSession, NewSnapshot, SessionSummary,
    SessionTransport, SnapshotKind, TerminalGrid, WorkspaceDetail, WorkspaceSummary,
};
use zstd::stream::{decode_all, encode_all};

impl Store {
    pub fn record_snapshot(&self, input: NewSnapshot) -> rusqlite::Result<()> {
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let json = serde_json::to_vec(&input.grid).unwrap();
        let compressed = encode_all(json.as_slice(), 1).unwrap();
        self.conn.execute(
            "insert into snapshots (id, session_id, kind, cwd, captured_at, payload)
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                Uuid::new_v4().to_string(),
                input.session_id,
                match input.kind { SnapshotKind::Checkpoint => "checkpoint", SnapshotKind::Final => "final" },
                input.cwd,
                now,
                compressed,
            ],
        )?;
        Ok(())
    }

    pub fn reconcile_interrupted_sessions(&self) -> rusqlite::Result<()> {
        let now = OffsetDateTime::now_utc().unix_timestamp();
        self.conn.execute(
            "update sessions
             set state = 'interrupted',
                 close_reason = 'app_crashed',
                 updated_at = ?1
             where state = 'live' and ended_at is null",
            params![now],
        )?;
        Ok(())
    }

    pub fn list_workspace_summaries(&self) -> rusqlite::Result<Vec<WorkspaceSummary>> {
        let mut stmt = self.conn.prepare(
            "select
                w.id,
                w.name,
                w.updated_at,
                sum(case when s.state = 'live' then 1 else 0 end) as live_sessions,
                sum(case when s.state != 'live' then 1 else 0 end) as closed_sessions,
                max(case when s.state = 'interrupted' then 1 else 0 end) as has_interrupted
             from workspaces w
             left join sessions s on s.workspace_id = w.id
             group by w.id, w.name, w.updated_at
             order by w.updated_at desc, w.rowid desc",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(WorkspaceSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                updated_at: row.get(2)?,
                live_sessions: row.get(3)?,
                recently_closed_sessions: row.get(4)?,
                has_interrupted_sessions: row.get::<_, i64>(5)? > 0,
            })
        })?;
        rows.collect()
    }

    fn latest_snapshot_for(&self, session_id: &str) -> rusqlite::Result<TerminalGrid> {
        let payload: Vec<u8> = self.conn.query_row(
            "select payload from snapshots where session_id = ?1 order by captured_at desc limit 1",
            params![session_id],
            |row| row.get(0),
        )?;
        let decoded = decode_all(payload.as_slice()).unwrap();
        Ok(serde_json::from_slice(&decoded).unwrap())
    }

    pub fn workspace_detail(&self, workspace_id: &str) -> rusqlite::Result<WorkspaceDetail> {
        let mut detail = self.conn.query_row(
            "select id, name, note_body from workspaces where id = ?1",
            params![workspace_id],
            |row| {
                Ok(WorkspaceDetail {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    note_body: row.get(2)?,
                    live_sessions: Vec::new(),
                    closed_sessions: Vec::new(),
                })
            },
        )?;

        let mut stmt = self.conn.prepare(
            "select id, title, transport, target_label, last_cwd, close_reason, state, shell
             from sessions where workspace_id = ?1 order by updated_at desc",
        )?;
        let rows = stmt.query_map(params![workspace_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, String>(7)?,
            ))
        })?;

        for row in rows {
            let (session_id, title, transport_raw, target_label, last_cwd, close_reason_raw, state, shell) = row?;
            let transport = if transport_raw == "ssh" {
                SessionTransport::Ssh
            } else {
                SessionTransport::Local
            };
            let close_reason = match close_reason_raw.as_deref() {
                Some("process_exited") => CloseReason::ProcessExited,
                Some("ssh_disconnected") => CloseReason::SshDisconnected,
                Some("app_crashed") => CloseReason::AppCrashed,
                Some("host_quit") => CloseReason::HostQuit,
                _ => CloseReason::UserClosed,
            };

            if state == "live" {
                detail.live_sessions.push(SessionSummary {
                    id: session_id,
                    title,
                    transport,
                    target_label,
                    last_cwd,
                    close_reason,
                });
                continue;
            }

            let snapshot_preview = self
                .latest_snapshot_for(&session_id)
                .unwrap_or_else(|_| TerminalGrid::from_lines(80, 24, &["<no snapshot>"]));
            let restore_recipe = build_restore_recipe(transport, &target_label, &shell, last_cwd.as_deref());

            detail.closed_sessions.push(ClosedSessionSummary {
                id: session_id,
                title,
                transport,
                target_label,
                last_cwd,
                close_reason,
                snapshot_preview,
                restore_recipe,
            });
        }

        Ok(detail)
    }
}
```

```rust
// store.rs migration addition
create table if not exists snapshots (
    id text primary key,
    session_id text not null,
    kind text not null,
    cwd text,
    captured_at integer not null,
    payload blob not null
);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p workspace-core --test workspace_store --test session_lifecycle --test snapshot_restore --test interrupted_recovery -v`  
Expected: PASS with all four tests ending in `... ok`

- [ ] **Step 5: Commit**

```bash
git add crates/workspace-core
git commit -m "feat: add snapshots restore recipes and interruption recovery"
```

## Task 4: Expose the Rust core through a Swift-friendly bridge

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/workspace-ffi/Cargo.toml`
- Create: `crates/workspace-ffi/build.rs`
- Create: `crates/workspace-ffi/src/lib.rs`
- Create: `crates/workspace-ffi/src/api.udl`
- Create: `scripts/generate-swift-bindings.sh`
- Test: `crates/workspace-ffi/tests/service_smoke.rs`

- [ ] **Step 1: Write the failing bridge smoke test**

```rust
// crates/workspace-ffi/tests/service_smoke.rs
use workspace_ffi::WorkspaceService;

#[test]
fn workspace_service_returns_workspace_detail_for_swift() {
    let service = WorkspaceService::new().unwrap();
    let workspace_id = service.create_workspace("spark3").unwrap();
    service.update_workspace_note(&workspace_id, "check release flow").unwrap();

    let detail = service.workspace_detail(&workspace_id).unwrap();
    assert_eq!(detail.name, "spark3");
    assert_eq!(detail.note_body, "check release flow");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p workspace-ffi --test service_smoke -v`  
Expected: FAIL with `package ID specification 'workspace-ffi' did not match any packages`

- [ ] **Step 3: Write the minimal bridge and binding generator**

```toml
# Cargo.toml
[workspace]
members = ["crates/workspace-core", "crates/workspace-ffi"]
resolver = "2"
```

```toml
# crates/workspace-ffi/Cargo.toml
[package]
name = "workspace-ffi"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib", "cdylib", "rlib"]

[dependencies]
uniffi = { version = "0.28", features = ["cli"] }
workspace-core = { path = "../workspace-core" }

[build-dependencies]
uniffi = { version = "0.28", features = ["build"] }
```

```rust
// crates/workspace-ffi/build.rs
fn main() {
    uniffi::generate_scaffolding("src/api.udl").unwrap();
}
```

```idl
// crates/workspace-ffi/src/api.udl
namespace workspaceffi {
    record WorkspaceDetail {
        string id;
        string name;
        string note_body;
    };

    interface WorkspaceService {
        constructor();
        string create_workspace(string name);
        void update_workspace_note(string workspace_id, string note_body);
        WorkspaceDetail workspace_detail(string workspace_id);
    };
}
```

```rust
// crates/workspace-ffi/src/lib.rs
use std::sync::Mutex;
use uniffi::Object;
use workspace_core::Store;

#[derive(Object)]
pub struct WorkspaceService {
    store: Mutex<Store>,
}

#[derive(uniffi::Record)]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub note_body: String,
}

#[uniffi::export]
impl WorkspaceService {
    #[uniffi::constructor]
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            store: Mutex::new(Store::open(":memory:").map_err(|err| err.to_string())?),
        })
    }

    pub fn create_workspace(&self, name: String) -> Result<String, String> {
        self.store.lock().unwrap().create_workspace(&name).map_err(|err| err.to_string())
    }

    pub fn update_workspace_note(&self, workspace_id: String, note_body: String) -> Result<(), String> {
        self.store.lock().unwrap().update_workspace_note(&workspace_id, &note_body).map_err(|err| err.to_string())
    }

    pub fn workspace_detail(&self, workspace_id: String) -> Result<WorkspaceDetail, String> {
        let detail = self.store.lock().unwrap().workspace_detail(&workspace_id).map_err(|err| err.to_string())?;
        Ok(WorkspaceDetail {
            id: detail.id,
            name: detail.name,
            note_body: detail.note_body,
        })
    }
}

uniffi::include_scaffolding!("api");
```

```bash
# scripts/generate-swift-bindings.sh
#!/usr/bin/env bash
set -euo pipefail

mkdir -p apps/macos/StatefulTerminal/Bridge
uniffi-bindgen generate \
  crates/workspace-ffi/src/api.udl \
  --language swift \
  --out-dir apps/macos/StatefulTerminal/Bridge
```

- [ ] **Step 4: Run the bridge test and generate bindings**

Run: `cargo test -p workspace-ffi --test service_smoke -v && bash scripts/generate-swift-bindings.sh`  
Expected: PASS with `test workspace_service_returns_workspace_detail_for_swift ... ok`, then generated Swift files in `apps/macos/StatefulTerminal/Bridge`

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/workspace-ffi scripts/generate-swift-bindings.sh
git commit -m "feat: expose workspace core through uniffi bridge"
```

## Task 5: Build the macOS workspace-first shell and note UI

**Files:**
- Create: `apps/macos/project.yml`
- Create: `apps/macos/StatefulTerminal/App/StatefulTerminalApp.swift`
- Create: `apps/macos/StatefulTerminal/App/AppDelegate.swift`
- Create: `apps/macos/StatefulTerminal/Bridge/WorkspaceCoreClient.swift`
- Create: `apps/macos/StatefulTerminal/Bridge/StatefulTerminal-Bridging-Header.h`
- Create: `apps/macos/StatefulTerminal/Models/AppModel.swift`
- Create: `apps/macos/StatefulTerminal/Models/WorkspaceViewData.swift`
- Create: `apps/macos/StatefulTerminal/Views/WorkspaceListView.swift`
- Create: `apps/macos/StatefulTerminal/Views/WorkspaceDetailView.swift`
- Create: `apps/macos/StatefulTerminal/Views/WorkspaceNoteView.swift`
- Test: `apps/macos/StatefulTerminalTests/AppModelTests.swift`

- [ ] **Step 1: Write the failing macOS app-model test**

```swift
// apps/macos/StatefulTerminalTests/AppModelTests.swift
import XCTest
@testable import StatefulTerminal

final class AppModelTests: XCTestCase {
    func test_loads_workspace_summaries_and_the_selected_note() async throws {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false)
            ],
            detail: WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "check prod logs",
                liveSessions: [],
                closedSessions: []
            )
        )
        let model = AppModel(core: client)

        try await model.load()

        XCTAssertEqual(model.workspaces.map(\.name), ["release"])
        XCTAssertEqual(model.selectedWorkspace?.noteBody, "check prod logs")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate --spec apps/macos/project.yml && xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS'`  
Expected: FAIL because `project.yml` and app targets do not exist yet

- [ ] **Step 3: Write the minimal app shell**

```yaml
# apps/macos/project.yml
name: StatefulTerminal
options:
  minimumXcodeGenVersion: 2.38.0
targets:
  StatefulTerminal:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - StatefulTerminal
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.jinto.stateful-terminal
        SWIFT_OBJC_BRIDGING_HEADER: StatefulTerminal/Bridge/StatefulTerminal-Bridging-Header.h
  StatefulTerminalTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - StatefulTerminalTests
    dependencies:
      - target: StatefulTerminal
```

```swift
// apps/macos/StatefulTerminal/App/StatefulTerminalApp.swift
import SwiftUI

@main
struct StatefulTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel(core: WorkspaceCoreClient.live)

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                WorkspaceListView(model: model)
            } detail: {
                WorkspaceDetailView(model: model)
            }
            .frame(minWidth: 1200, minHeight: 760)
            .task { try? await model.load() }
        }
    }
}
```

```swift
// apps/macos/StatefulTerminal/Models/AppModel.swift
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [WorkspaceSummaryViewData] = []
    @Published var selectedWorkspace: WorkspaceDetailViewData?
    @Published var noteDraft: String = ""
    @Published var liveSessions: [SessionViewData] = []
    @Published var closedSessions: [ClosedSessionViewData] = []

    private let core: WorkspaceCoreClientProtocol

    init(core: WorkspaceCoreClientProtocol) {
        self.core = core
    }

    func load() async throws {
        workspaces = try await core.listWorkspaceSummaries()
        if let first = workspaces.first {
            selectedWorkspace = try await core.workspaceDetail(id: first.id)
            noteDraft = selectedWorkspace?.noteBody ?? ""
            liveSessions = selectedWorkspace?.liveSessions ?? []
            closedSessions = selectedWorkspace?.closedSessions ?? []
        }
    }

    func saveNote() async throws {
        guard let workspace = selectedWorkspace else { return }
        try await core.updateWorkspaceNote(id: workspace.id, noteBody: noteDraft)
        selectedWorkspace?.noteBody = noteDraft
    }
}
```

```swift
// apps/macos/StatefulTerminal/Bridge/WorkspaceCoreClient.swift
import Foundation

protocol WorkspaceCoreClientProtocol {
    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData]
    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData
    func updateWorkspaceNote(id: String, noteBody: String) async throws
    func recordFinalSnapshotAndClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) async throws
    func openLocalShellHere(sessionID: String) async throws
    func reconnectSSH(sessionID: String, cdIntoDirectory: Bool) async throws
}

enum WorkspaceCoreClient {
    static let live: WorkspaceCoreClientProtocol = MockWorkspaceCoreClient(summaries: [], detail: nil)
}

final class MockWorkspaceCoreClient: WorkspaceCoreClientProtocol {
    private let summaries: [WorkspaceSummaryViewData]
    private var detail: WorkspaceDetailViewData?
    private(set) var lastRecoveryAction: String?
    private(set) var closedSessionIDs: [String] = []

    init(summaries: [WorkspaceSummaryViewData], detail: WorkspaceDetailViewData?) {
        self.summaries = summaries
        self.detail = detail
    }

    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData] { summaries }
    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData { detail! }
    func updateWorkspaceNote(id: String, noteBody: String) async throws { detail?.noteBody = noteBody }
    func recordFinalSnapshotAndClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) async throws {
        closedSessionIDs.append(sessionID)
    }
    func openLocalShellHere(sessionID: String) async throws {
        lastRecoveryAction = "open-local:\(sessionID)"
    }
    func reconnectSSH(sessionID: String, cdIntoDirectory: Bool) async throws {
        lastRecoveryAction = cdIntoDirectory ? "reconnect-ssh-cd:\(sessionID)" : "reconnect-ssh:\(sessionID)"
    }

    static func workspaceWithOneLiveSession() -> MockWorkspaceCoreClient {
        MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false)
            ],
            detail: WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "check prod logs",
                liveSessions: [
                    SessionViewData(
                        id: "session-prod",
                        title: "prod logs",
                        targetLabel: "prod",
                        lastCwd: "/srv/app",
                        restoreRecipe: RestoreRecipeViewData(launchCommand: "ssh prod -- 'cd /srv/app && exec zsh -l'")
                    )
                ],
                closedSessions: []
            )
        )
    }

    static func workspaceWithInterruptedSession() -> MockWorkspaceCoreClient {
        MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-spark3", name: "spark3", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true)
            ],
            detail: WorkspaceDetailViewData(
                id: "ws-spark3",
                name: "spark3",
                noteBody: "resume after crash",
                liveSessions: [],
                closedSessions: [
                    ClosedSessionViewData(
                        id: "session-interrupted",
                        title: "shell",
                        targetLabel: "local",
                        lastCwd: "/Users/jinto/projects/spark3",
                        lastCommand: "cargo test -p workspace-core",
                        closeReason: .appCrashed,
                        snapshotPreview: .fixture(lines: ["cargo test -p workspace-core", "test result: interrupted"]),
                        restoreRecipe: RestoreRecipeViewData(launchCommand: "zsh -lc 'cd /Users/jinto/projects/spark3 && exec zsh -l'")
                    )
                ]
            )
        )
    }
}
```

```swift
// apps/macos/StatefulTerminal/Models/WorkspaceViewData.swift
import Foundation

struct WorkspaceSummaryViewData: Identifiable, Equatable {
    let id: String
    let name: String
    let liveSessions: Int
    let recentlyClosedSessions: Int
    let hasInterruptedSessions: Bool
}

struct RestoreRecipeViewData: Equatable {
    let launchCommand: String
}

enum CloseReasonViewData: Equatable {
    case userClosed
    case processExited
    case sshDisconnected
    case appCrashed
    case hostQuit
}

struct SessionViewData: Identifiable, Equatable {
    let id: String
    let title: String
    let targetLabel: String
    let lastCwd: String?
    let restoreRecipe: RestoreRecipeViewData

    static func fixture() -> SessionViewData {
        SessionViewData(
            id: "fixture-session",
            title: "fixture",
            targetLabel: "local",
            lastCwd: "/tmp",
            restoreRecipe: RestoreRecipeViewData(launchCommand: "zsh -l")
        )
    }
}

struct ClosedSessionViewData: Identifiable, Equatable {
    let id: String
    let title: String
    let targetLabel: String
    let lastCwd: String?
    let lastCommand: String?
    let closeReason: CloseReasonViewData
    let snapshotPreview: TerminalSnapshotViewData
    let restoreRecipe: RestoreRecipeViewData
}

struct WorkspaceDetailViewData: Equatable {
    let id: String
    let name: String
    var noteBody: String
    let liveSessions: [SessionViewData]
    let closedSessions: [ClosedSessionViewData]
}
```

```objc
// apps/macos/StatefulTerminal/Bridge/StatefulTerminal-Bridging-Header.h
#import "workspaceffiFFI.h"
```

```swift
// apps/macos/StatefulTerminal/App/AppDelegate.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {}
```

```swift
// apps/macos/StatefulTerminal/Views/WorkspaceListView.swift
import SwiftUI

struct WorkspaceListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(model.workspaces, id: \.id) { workspace in
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name).font(.headline)
                Text("\(workspace.liveSessions) live · \(workspace.recentlyClosedSessions) closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

```swift
// apps/macos/StatefulTerminal/Views/WorkspaceDetailView.swift
import SwiftUI

struct WorkspaceDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let workspace = model.selectedWorkspace {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(workspace.name).font(.largeTitle)
                    Spacer()
                }
                WorkspaceNoteView(noteBody: $model.noteDraft, onSave: {
                    Task { try? await model.saveNote() }
                })
                    .frame(width: 320)
            }
            .padding(24)
        } else {
            Text("Select a workspace")
        }
    }
}
```

```swift
// apps/macos/StatefulTerminal/Views/WorkspaceNoteView.swift
import SwiftUI

struct WorkspaceNoteView: View {
    @Binding var noteBody: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text("Workspace Note").font(.headline)
            TextEditor(text: $noteBody)
                .font(.body.monospaced())
            Button("Save", action: onSave)
        }
    }
}
```

- [ ] **Step 4: Run the app-model test to verify it passes**

Run: `xcodegen generate --spec apps/macos/project.yml && xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS'`  
Expected: PASS with `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/macos/project.yml apps/macos/StatefulTerminal apps/macos/StatefulTerminalTests
git commit -m "feat: add workspace-first macOS shell"
```

## Task 6: Add live session hosting, close behavior, and recently closed cards with a mock terminal host

**Files:**
- Create: `apps/macos/StatefulTerminal/Terminal/TerminalHostProtocol.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/MockTerminalHost.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/TerminalSurfaceHostView.swift`
- Create: `apps/macos/StatefulTerminal/Views/RecentlyClosedSessionCardView.swift`
- Modify: `apps/macos/StatefulTerminal/Models/AppModel.swift`
- Modify: `apps/macos/StatefulTerminal/Views/WorkspaceDetailView.swift`
- Test: `apps/macos/StatefulTerminalTests/WorkspaceFlowTests.swift`

- [ ] **Step 1: Write the failing workspace flow test**

```swift
// apps/macos/StatefulTerminalTests/WorkspaceFlowTests.swift
import XCTest
@testable import StatefulTerminal

final class WorkspaceFlowTests: XCTestCase {
    func test_closing_a_live_session_moves_it_to_recently_closed() async throws {
        let core = MockWorkspaceCoreClient.workspaceWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })

        try await model.load()
        try await model.attachLiveSessions()
        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log", "error line"]),
            closeReason: .userClosed
        )

        XCTAssertEqual(model.liveSessions.count, 0)
        XCTAssertEqual(model.closedSessions.first?.title, "prod logs")
        XCTAssertEqual(model.closedSessions.first?.snapshotPreview.lines[1], "error line")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -only-testing:StatefulTerminalTests/WorkspaceFlowTests`  
Expected: FAIL with missing types such as `TerminalHostProtocol`, `attachLiveSessions`, or `closedSessions`

- [ ] **Step 3: Write the minimal session-hosting and close-flow implementation**

```swift
// apps/macos/StatefulTerminal/Terminal/TerminalHostProtocol.swift
import Foundation

struct TerminalSnapshotViewData: Equatable {
    let cols: Int
    let rows: Int
    let lines: [String]

    static func fixture(lines: [String]) -> TerminalSnapshotViewData {
        TerminalSnapshotViewData(cols: 80, rows: 24, lines: lines)
    }
}

protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData)
}

protocol TerminalHostProtocol {
    var delegate: TerminalHostDelegate? { get set }
    func attach(sessionID: String)
    func close(sessionID: String)
}
```

```swift
// apps/macos/StatefulTerminal/Terminal/MockTerminalHost.swift
import Foundation

final class MockTerminalHost: TerminalHostProtocol {
    weak var delegate: TerminalHostDelegate?

    func attach(sessionID: String) {}
    func close(sessionID: String) {}

    func finishClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        delegate?.terminalHostDidClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason)
    }
}
```

```swift
// apps/macos/StatefulTerminal/Models/AppModel.swift
private let terminalFactory: (SessionViewData) -> TerminalHostProtocol
private var hosts: [String: TerminalHostProtocol] = [:]

init(
    core: WorkspaceCoreClientProtocol,
    terminalFactory: @escaping (SessionViewData) -> TerminalHostProtocol = { _ in MockTerminalHost() }
) {
    self.core = core
    self.terminalFactory = terminalFactory
}

func attachLiveSessions() async throws {
    guard let workspace = selectedWorkspace else { return }
    liveSessions = workspace.liveSessions
    closedSessions = workspace.closedSessions
    for session in liveSessions {
        let host = terminalFactory(session)
        host.delegate = self
        host.attach(sessionID: session.id)
        hosts[session.id] = host
    }
}
```

```swift
// AppModel terminal close delegate conformance
extension AppModel: TerminalHostDelegate {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        guard let index = liveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = liveSessions.remove(at: index)
        let closed = ClosedSessionViewData(
            id: session.id,
            title: session.title,
            targetLabel: session.targetLabel,
            lastCwd: session.lastCwd,
            lastCommand: nil,
            closeReason: closeReason,
            snapshotPreview: snapshot,
            restoreRecipe: session.restoreRecipe
        )
        closedSessions.insert(closed, at: 0)
        Task { try? await core.recordFinalSnapshotAndClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason) }
    }
}
```

```swift
// apps/macos/StatefulTerminal/Terminal/TerminalSurfaceHostView.swift
import SwiftUI

struct TerminalSurfaceHostView: View {
    let session: SessionViewData

    var body: some View {
        VStack(alignment: .leading) {
            Text(session.title).font(.headline)
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.9))
                .overlay(alignment: .topLeading) {
                    Text(session.restoreRecipe.launchCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(12)
                }
        }
    }
}
```

```swift
// apps/macos/StatefulTerminal/Views/WorkspaceDetailView.swift
import SwiftUI

struct WorkspaceDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let workspace = model.selectedWorkspace {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(workspace.name).font(.largeTitle)
                    ForEach(model.liveSessions) { session in
                        TerminalSurfaceHostView(session: session)
                            .frame(height: 180)
                    }
                    ForEach(model.closedSessions) { session in
                        RecentlyClosedSessionCardView(session: session)
                    }
                }
                WorkspaceNoteView(noteBody: $model.noteDraft, onSave: {
                    Task { try? await model.saveNote() }
                })
                .frame(width: 320)
            }
            .padding(24)
        } else {
            Text("Select a workspace")
        }
    }
}
```

```swift
// apps/macos/StatefulTerminal/Views/RecentlyClosedSessionCardView.swift
import SwiftUI

struct RecentlyClosedSessionCardView: View {
    let session: ClosedSessionViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.headline)
            Text("\(session.targetLabel) · \(session.lastCwd ?? "unknown cwd")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.snapshotPreview.lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(4)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 4: Run the workspace flow test to verify it passes**

Run: `xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -only-testing:StatefulTerminalTests/WorkspaceFlowTests`  
Expected: PASS with `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/macos/StatefulTerminal apps/macos/StatefulTerminalTests
git commit -m "feat: add mock live session hosting and close flow"
```

## Task 7: Add recovery actions and interrupted-session handling on relaunch

**Files:**
- Modify: `crates/workspace-ffi/src/lib.rs`
- Modify: `apps/macos/StatefulTerminal/Models/AppModel.swift`
- Create: `apps/macos/StatefulTerminal/Views/ClosedSessionInspectorView.swift`
- Test: `apps/macos/StatefulTerminalTests/RecoveryActionsTests.swift`

- [ ] **Step 1: Write the failing recovery-actions test**

```swift
// apps/macos/StatefulTerminalTests/RecoveryActionsTests.swift
import XCTest
@testable import StatefulTerminal

final class RecoveryActionsTests: XCTestCase {
    func test_interrupted_session_exposes_manual_recovery_actions() async throws {
        let client = MockWorkspaceCoreClient.workspaceWithInterruptedSession()
        let model = AppModel(core: client)

        try await model.load()

        let actions = model.recoveryActions(for: model.closedSessions[0])
        XCTAssertEqual(actions.map(\.title), [
            "Open local shell here",
            "Reconnect SSH",
            "Reconnect SSH and cd here",
            "Copy last command",
            "Copy session recipe",
        ])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -only-testing:StatefulTerminalTests/RecoveryActionsTests`  
Expected: FAIL with missing `recoveryActions` or missing interrupted-session fixture data

- [ ] **Step 3: Write the minimal recovery implementation**

```swift
// apps/macos/StatefulTerminal/Models/AppModel.swift
struct RecoveryActionViewData {
    let title: String
    let perform: () -> Void
}

func recoveryActions(for session: ClosedSessionViewData) -> [RecoveryActionViewData] {
    [
        RecoveryActionViewData(title: "Open local shell here", perform: { [core] in
            Task { try? await core.openLocalShellHere(sessionID: session.id) }
        }),
        RecoveryActionViewData(title: "Reconnect SSH", perform: { [core] in
            Task { try? await core.reconnectSSH(sessionID: session.id, cdIntoDirectory: false) }
        }),
        RecoveryActionViewData(title: "Reconnect SSH and cd here", perform: { [core] in
            Task { try? await core.reconnectSSH(sessionID: session.id, cdIntoDirectory: true) }
        }),
        RecoveryActionViewData(title: "Copy last command", perform: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.lastCommand ?? "", forType: .string)
        }),
        RecoveryActionViewData(title: "Copy session recipe", perform: { NSPasteboard.general.setString(session.restoreRecipe.launchCommand, forType: .string) }),
    ]
}
```

```swift
// apps/macos/StatefulTerminal/Views/ClosedSessionInspectorView.swift
import SwiftUI

struct ClosedSessionInspectorView: View {
    let session: ClosedSessionViewData
    let actions: [RecoveryActionViewData]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.title2)
            Text(session.snapshotPreview.lines.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].title, action: actions[index].perform)
            }
        }
        .padding(16)
    }
}
```

```rust
// crates/workspace-ffi/src/lib.rs
#[uniffi::export]
impl WorkspaceService {
    pub fn reconcile_interrupted_sessions(&self) -> Result<(), String> {
        self.store.lock().unwrap().reconcile_interrupted_sessions().map_err(|err| err.to_string())
    }
}
```

- [ ] **Step 4: Run the recovery-actions test to verify it passes**

Run: `xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -only-testing:StatefulTerminalTests/RecoveryActionsTests`  
Expected: PASS with `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add crates/workspace-ffi apps/macos/StatefulTerminal apps/macos/StatefulTerminalTests
git commit -m "feat: add interrupted-session recovery actions"
```

## Task 8: Integrate the Ghostty-first terminal adapter behind a factory and keep a safe fallback

**Files:**
- Create: `apps/macos/StatefulTerminal/Terminal/TerminalHostFactory.swift`
- Create: `apps/macos/StatefulTerminal/Terminal/GhosttyTerminalHost.swift`
- Modify: `apps/macos/project.yml`
- Modify: `apps/macos/StatefulTerminal/Bridge/StatefulTerminal-Bridging-Header.h`
- Create: `scripts/build-macos.sh`
- Test: `apps/macos/StatefulTerminalTests/TerminalHostFactoryTests.swift`

- [ ] **Step 1: Write the failing terminal-host-factory test**

```swift
// apps/macos/StatefulTerminalTests/TerminalHostFactoryTests.swift
import XCTest
@testable import StatefulTerminal

final class TerminalHostFactoryTests: XCTestCase {
    func test_factory_falls_back_to_mock_host_when_ghostty_is_unavailable() {
        let factory = TerminalHostFactory(loadGhosttyHandle: { nil })
        let host = factory.makeHost(for: .fixture())
        XCTAssertTrue(host is MockTerminalHost)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -only-testing:StatefulTerminalTests/TerminalHostFactoryTests`  
Expected: FAIL with missing `TerminalHostFactory` or `GhosttyTerminalHost`

- [ ] **Step 3: Write the minimal Ghostty-first adapter and fallback build path**

```swift
// apps/macos/StatefulTerminal/Terminal/TerminalHostFactory.swift
import Foundation

struct TerminalHostFactory {
    let loadGhosttyHandle: () -> UnsafeMutableRawPointer?

    func makeHost(for session: SessionViewData) -> TerminalHostProtocol {
        if let handle = loadGhosttyHandle() {
            return GhosttyTerminalHost(handle: handle, session: session)
        }
        return MockTerminalHost()
    }
}
```

```swift
// apps/macos/StatefulTerminal/Terminal/GhosttyTerminalHost.swift
import Foundation

final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: TerminalHostDelegate?
    private let handle: UnsafeMutableRawPointer
    private let session: SessionViewData

    init(handle: UnsafeMutableRawPointer, session: SessionViewData) {
        self.handle = handle
        self.session = session
    }

    func attach(sessionID: String) {
        ghostty_surface_start(handle, session.restoreRecipe.launchCommand)
    }

    func close(sessionID: String) {
        ghostty_surface_close(handle)
        delegate?.terminalHostDidClose(
            sessionID: sessionID,
            snapshot: .fixture(lines: ["ghostty session closed"]),
            closeReason: .userClosed
        )
    }
}
```

```objc
// apps/macos/StatefulTerminal/Bridge/StatefulTerminal-Bridging-Header.h
#import "workspaceffiFFI.h"

void *ghostty_surface_create(void);
void ghostty_surface_start(void *handle, const char *command);
void ghostty_surface_close(void *handle);
```

```yaml
# apps/macos/project.yml
targets:
  StatefulTerminal:
    settings:
      base:
        HEADER_SEARCH_PATHS: $(SRCROOT)/StatefulTerminal/Bridge $(GHOSTTY_SDK_PATH)
        LIBRARY_SEARCH_PATHS: $(GHOSTTY_SDK_PATH)
        OTHER_LDFLAGS: $(inherited) -lghostty
        OTHER_SWIFT_FLAGS: $(inherited) -D GHOSTTY_FIRST
```

```bash
# scripts/build-macos.sh
#!/usr/bin/env bash
set -euo pipefail

xcodegen generate --spec apps/macos/project.yml
xcodebuild build \
  -project apps/macos/StatefulTerminal.xcodeproj \
  -scheme StatefulTerminal \
  -destination 'platform=macOS'
```

- [ ] **Step 4: Run automated tests and the macOS build**

Run: `xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -only-testing:StatefulTerminalTests/TerminalHostFactoryTests && bash scripts/build-macos.sh`  
Expected: PASS with `** TEST SUCCEEDED **`, then `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/macos/project.yml apps/macos/StatefulTerminal apps/macos/StatefulTerminalTests scripts/build-macos.sh
git commit -m "feat: add ghostty first terminal host factory"
```

## Final Verification Sweep

- [ ] Run: `cargo test -p workspace-core -v`
- [ ] Expected: all Rust core tests pass
- [ ] Run: `cargo test -p workspace-ffi -v`
- [ ] Expected: all Rust bridge tests pass
- [ ] Run: `xcodegen generate --spec apps/macos/project.yml && xcodebuild test -project apps/macos/StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS'`
- [ ] Expected: `** TEST SUCCEEDED **`
- [ ] Run: `bash scripts/build-macos.sh`
- [ ] Expected: `** BUILD SUCCEEDED **`

## Spec Coverage Check

- Workspace-first UI: Task 5
- Workspace note: Tasks 2 and 5
- Explicit workspace grouping: Task 5 with `AppModel` and workspace detail loading
- Closing a tab ends the process: Task 6
- Metadata plus terminal snapshot memory: Tasks 3 and 6
- Manual recovery actions only: Task 7
- Interrupted-session detection on relaunch: Tasks 3 and 7
- Ghostty-first adapter behind an abstraction boundary: Task 8

## Placeholder Scan

- No deferred implementation markers are allowed in executed code.
- Keep the Ghostty adapter behind `TerminalHostFactory`; do not leak Ghostty-specific types into `AppModel` or Rust.
- If Ghostty embedding symbols are unavailable on the first integration pass, keep the fallback host working and land the adapter boundary first rather than blocking the whole app.
