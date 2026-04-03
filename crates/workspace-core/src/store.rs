use rusqlite::{params, Connection, OptionalExtension};

use crate::{
    build_restore_recipe, CloseReason, ClosedSessionSummary, NewSession, NewSnapshot, SessionState,
    SessionSummary, SessionTransport, SnapshotKind, TerminalGrid, WorkspaceDetail,
    WorkspaceSummary,
};

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch("pragma foreign_keys = on;")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn create_workspace(&self, name: &str) -> rusqlite::Result<String> {
        let updated_at = now();
        self.conn.execute(
            "insert into workspaces (id, name, note_body, updated_at, last_opened_at)
             values (lower(hex(randomblob(16))), ?1, '', ?2, ?2)",
            params![name, updated_at],
        )?;

        self.conn.query_row(
            "select id from workspaces where rowid = last_insert_rowid()",
            [],
            |row| row.get(0),
        )
    }

    pub fn list_workspace_summaries(&self) -> rusqlite::Result<Vec<WorkspaceSummary>> {
        let mut stmt = self.conn.prepare(
            "select
                w.id,
                w.name,
                w.updated_at,
                coalesce(sum(case when s.state = 'live' then 1 else 0 end), 0),
                coalesce(sum(case when s.state in ('closed','exited','lost','crashed') then 1 else 0 end), 0),
                coalesce(max(case when s.state = 'interrupted' then 1 else 0 end), 0)
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
                has_interrupted_sessions: row.get::<_, i64>(5)? != 0,
            })
        })?;

        rows.collect()
    }

    pub fn update_workspace_note(
        &self,
        workspace_id: &str,
        note_body: &str,
    ) -> rusqlite::Result<()> {
        let updated_at = now();
        self.conn.execute(
            "update workspaces
             set note_body = ?2, updated_at = ?3
             where id = ?1",
            params![workspace_id, note_body, updated_at],
        )?;
        Ok(())
    }

    pub fn start_session(&self, input: NewSession) -> rusqlite::Result<String> {
        let updated_at = now();
        self.conn.execute(
            "insert into sessions (
                id, workspace_id, transport, target_label, title, shell,
                initial_cwd, last_cwd, state, close_reason, exit_status,
                updated_at, created_at
             )
             values (
                lower(hex(randomblob(16))), ?1, ?2, ?3, ?4, ?5,
                ?6, ?6, ?7, null, null,
                ?8, ?8
             )",
            params![
                input.workspace_id,
                session_transport_to_str(input.transport),
                input.target_label,
                input.title,
                input.shell,
                input.initial_cwd,
                session_state_to_str(SessionState::Live),
                updated_at,
            ],
        )?;

        let session_id: String = self.conn.query_row(
            "select id from sessions where rowid = last_insert_rowid()",
            [],
            |row| row.get(0),
        )?;

        self.touch_workspace(&input.workspace_id)?;
        Ok(session_id)
    }

    pub fn record_snapshot(&self, input: NewSnapshot) -> rusqlite::Result<()> {
        let created_at = now();
        self.conn.execute(
            "insert into snapshots (
                id, session_id, kind, cwd, cols, rows, line_count, payload, created_at
             )
             values (
                lower(hex(randomblob(16))), ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
             )",
            params![
                input.session_id,
                snapshot_kind_to_str(input.kind),
                input.cwd,
                i64::from(input.grid.cols),
                i64::from(input.grid.rows),
                input.grid.lines.len() as i64,
                encode_terminal_grid_lines(&input.grid),
                created_at,
            ],
        )?;

        self.touch_workspace_by_session(&input.session_id)?;
        Ok(())
    }

    pub fn close_session(
        &self,
        session_id: &str,
        reason: CloseReason,
        last_cwd: Option<String>,
        exit_status: Option<i64>,
    ) -> rusqlite::Result<()> {
        let updated_at = now();
        let changed = self.conn.execute(
            "update sessions
             set state = ?2,
                 close_reason = ?3,
                 last_cwd = coalesce(?4, last_cwd),
                 exit_status = ?5,
                 updated_at = ?6
             where id = ?1 and state = ?7",
            params![
                session_id,
                session_state_to_str(SessionState::Closed),
                close_reason_to_str(reason),
                last_cwd,
                exit_status,
                updated_at,
                session_state_to_str(SessionState::Live),
            ],
        )?;

        if changed == 0 {
            let exists = self.conn.query_row(
                "select 1 from sessions where id = ?1",
                params![session_id],
                |_| Ok(()),
            );

            if exists.is_ok() {
                return Ok(());
            }

            return Err(rusqlite::Error::QueryReturnedNoRows);
        }

        self.touch_workspace_by_session(session_id)?;

        Ok(())
    }

    pub fn reconcile_interrupted_sessions(&self) -> rusqlite::Result<()> {
        let updated_at = now();
        let mut stmt = self.conn.prepare(
            "select id
             from sessions
             where state = ?1",
        )?;
        let session_ids = stmt
            .query_map(params![session_state_to_str(SessionState::Live)], |row| {
                row.get(0)
            })?
            .collect::<rusqlite::Result<Vec<String>>>()?;

        self.conn.execute(
            "update sessions
             set state = ?1,
                 close_reason = ?2,
                 updated_at = ?3
             where state = ?4",
            params![
                session_state_to_str(SessionState::Interrupted),
                close_reason_to_str(CloseReason::AppCrashed),
                updated_at,
                session_state_to_str(SessionState::Live),
            ],
        )?;

        for session_id in session_ids {
            self.touch_workspace_by_session(&session_id)?;
        }

        Ok(())
    }

    pub fn workspace_detail(&self, workspace_id: &str) -> rusqlite::Result<WorkspaceDetail> {
        let workspace = self.conn.query_row(
            "select id, name, note_body
             from workspaces
             where id = ?1",
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

        let live_sessions = self.sessions_for_workspace(workspace_id, SessionState::Live)?;
        let closed_sessions = self.closed_sessions_for_workspace(workspace_id)?;

        Ok(WorkspaceDetail {
            live_sessions,
            closed_sessions,
            ..workspace
        })
    }

    fn migrate(&self) -> rusqlite::Result<()> {
        self.conn.execute_batch(
            "create table if not exists workspaces (
                id text primary key not null,
                name text not null,
                note_body text not null,
                updated_at integer not null,
                last_opened_at integer not null
            );

            create table if not exists sessions (
                id text primary key not null,
                workspace_id text not null references workspaces(id) on delete cascade,
                transport text not null,
                target_label text not null,
                title text not null,
                shell text not null,
                initial_cwd text,
                last_cwd text,
                state text not null,
                close_reason text,
                exit_status integer,
                updated_at integer not null,
                created_at integer not null
            );

            create table if not exists snapshots (
                id text primary key not null,
                session_id text not null references sessions(id) on delete cascade,
                kind text not null,
                cwd text,
                cols integer not null,
                rows integer not null,
                line_count integer not null,
                payload blob not null,
                created_at integer not null
            );

            create index if not exists idx_sessions_workspace_id on sessions(workspace_id);
            create index if not exists idx_sessions_state on sessions(state);
            create index if not exists idx_snapshots_session_id on snapshots(session_id);",
        )
    }

    fn sessions_for_workspace(
        &self,
        workspace_id: &str,
        state: SessionState,
    ) -> rusqlite::Result<Vec<SessionSummary>> {
        let mut stmt = self.conn.prepare(
            "select id, title, transport, target_label, last_cwd, close_reason
             from sessions
             where workspace_id = ?1 and state = ?2
             order by updated_at desc, rowid desc",
        )?;
        let rows = stmt.query_map(params![workspace_id, session_state_to_str(state)], |row| {
            Ok(SessionSummary {
                id: row.get(0)?,
                title: row.get(1)?,
                transport: session_transport_from_str(&row.get::<_, String>(2)?)?,
                target_label: row.get(3)?,
                last_cwd: row.get(4)?,
                close_reason: match row.get::<_, Option<String>>(5)? {
                    Some(ref s) => close_reason_from_str(s)?,
                    None => CloseReason::UserClosed,
                },
            })
        })?;

        rows.collect()
    }

    fn closed_sessions_for_workspace(
        &self,
        workspace_id: &str,
    ) -> rusqlite::Result<Vec<ClosedSessionSummary>> {
        let mut stmt = self.conn.prepare(
            "select id, title, transport, target_label, shell, initial_cwd, last_cwd, close_reason
             from sessions
             where workspace_id = ?1
               and state in ('closed', 'exited', 'lost', 'crashed', 'interrupted')
             order by updated_at desc, rowid desc",
        )?;
        let rows = stmt.query_map(params![workspace_id], |row| {
            let id: String = row.get(0)?;
            let transport = session_transport_from_str(&row.get::<_, String>(2)?)?;
            let initial_cwd: Option<String> = row.get(5)?;
            let last_cwd: Option<String> = row.get(6)?;
            let snapshot = self.latest_snapshot_for(&id)?;
            let snapshot_preview = snapshot
                .as_ref()
                .map(|snapshot| snapshot.grid.clone())
                .unwrap_or_else(TerminalGrid::empty);
            let restore_cwd = snapshot
                .as_ref()
                .and_then(|snapshot| snapshot.cwd.clone())
                .or_else(|| last_cwd.clone())
                .or_else(|| initial_cwd.clone());
            let shell: String = row.get(4)?;
            let restore_recipe = build_restore_recipe(
                transport,
                &row.get::<_, String>(3)?,
                &shell,
                restore_cwd.as_deref(),
            );

            Ok(ClosedSessionSummary {
                id,
                title: row.get(1)?,
                transport,
                target_label: row.get(3)?,
                last_cwd: restore_cwd,
                close_reason: match row.get::<_, Option<String>>(7)? {
                    Some(ref s) => close_reason_from_str(s)?,
                    None => CloseReason::UserClosed,
                },
                snapshot_preview,
                restore_recipe,
            })
        })?;

        rows.collect()
    }

    fn latest_snapshot_for(&self, session_id: &str) -> rusqlite::Result<Option<StoredSnapshot>> {
        self.conn
            .query_row(
                "select kind, cwd, cols, rows, line_count, payload
                 from snapshots
                 where session_id = ?1
                 order by created_at desc, rowid desc
                 limit 1",
                params![session_id],
                |row| {
                    let _kind: String = row.get(0)?;
                    Ok(StoredSnapshot {
                        cwd: row.get(1)?,
                        grid: TerminalGrid {
                            cols: safe_u16(row.get(2)?, "cols")?,
                            rows: safe_u16(row.get(3)?, "rows")?,
                            lines: decode_terminal_grid_lines(
                                row.get(4)?,
                                row.get::<_, Vec<u8>>(5)?,
                            )?,
                        },
                    })
                },
            )
            .optional()
    }

    fn touch_workspace(&self, workspace_id: &str) -> rusqlite::Result<()> {
        let updated_at = now();
        self.conn.execute(
            "update workspaces
             set updated_at = ?2
             where id = ?1",
            params![workspace_id, updated_at],
        )?;
        Ok(())
    }

    fn touch_workspace_by_session(&self, session_id: &str) -> rusqlite::Result<()> {
        let updated_at = now();
        self.conn.execute(
            "update workspaces set updated_at = ?2
             where id = (select workspace_id from sessions where id = ?1)",
            params![session_id, updated_at],
        )?;
        Ok(())
    }
}

fn safe_u16(value: i64, column: &str) -> rusqlite::Result<u16> {
    u16::try_from(value).map_err(|_| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Integer,
            format!("{column} value {value} out of u16 range").into(),
        )
    })
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before unix epoch")
        .as_nanos() as i64
}

fn session_transport_to_str(value: SessionTransport) -> &'static str {
    match value {
        SessionTransport::Local => "local",
        SessionTransport::Ssh => "ssh",
    }
}

fn session_transport_from_str(value: &str) -> rusqlite::Result<SessionTransport> {
    match value {
        "local" => Ok(SessionTransport::Local),
        "ssh" => Ok(SessionTransport::Ssh),
        other => Err(rusqlite::Error::FromSqlConversionFailure(
            2,
            rusqlite::types::Type::Text,
            format!("unknown session transport: {other}").into(),
        )),
    }
}

fn session_state_to_str(value: SessionState) -> &'static str {
    match value {
        SessionState::Live => "live",
        SessionState::Closed => "closed",
        SessionState::Exited => "exited",
        SessionState::Lost => "lost",
        SessionState::Crashed => "crashed",
        SessionState::Interrupted => "interrupted",
    }
}

fn close_reason_to_str(value: CloseReason) -> &'static str {
    match value {
        CloseReason::UserClosed => "user_closed",
        CloseReason::ProcessExited => "process_exited",
        CloseReason::SshDisconnected => "ssh_disconnected",
        CloseReason::AppCrashed => "app_crashed",
        CloseReason::HostQuit => "host_quit",
    }
}

fn close_reason_from_str(value: &str) -> rusqlite::Result<CloseReason> {
    match value {
        "user_closed" => Ok(CloseReason::UserClosed),
        "process_exited" => Ok(CloseReason::ProcessExited),
        "ssh_disconnected" => Ok(CloseReason::SshDisconnected),
        "app_crashed" => Ok(CloseReason::AppCrashed),
        "host_quit" => Ok(CloseReason::HostQuit),
        other => Err(rusqlite::Error::FromSqlConversionFailure(
            5,
            rusqlite::types::Type::Text,
            format!("unknown close reason: {other}").into(),
        )),
    }
}

fn snapshot_kind_to_str(value: SnapshotKind) -> &'static str {
    match value {
        SnapshotKind::Checkpoint => "checkpoint",
        SnapshotKind::Final => "final",
    }
}


fn encode_terminal_grid_lines(grid: &TerminalGrid) -> Vec<u8> {
    grid.lines.join("\n").into_bytes()
}

fn decode_terminal_grid_lines(line_count: i64, payload: Vec<u8>) -> rusqlite::Result<Vec<String>> {
    if line_count == 0 {
        return Ok(Vec::new());
    }

    let text = String::from_utf8(payload).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(5, rusqlite::types::Type::Blob, Box::new(error))
    })?;
    Ok(text.split('\n').map(str::to_owned).collect())
}

#[derive(Debug, Clone)]
struct StoredSnapshot {
    cwd: Option<String>,
    grid: TerminalGrid,
}
