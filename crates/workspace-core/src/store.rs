use rusqlite::{params, Connection};

use crate::{
    CloseReason, NewSession, SessionState, SessionSummary, SessionTransport, WorkspaceDetail,
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
                coalesce((
                    select count(*)
                    from sessions s
                    where s.workspace_id = w.id and s.state = 'live'
                ), 0) as live_sessions,
                coalesce((
                    select count(*)
                    from sessions s
                    where s.workspace_id = w.id
                      and s.state in ('closed', 'exited', 'lost', 'crashed')
                ), 0) as recently_closed_sessions,
                exists(
                    select 1
                    from sessions s
                    where s.workspace_id = w.id and s.state = 'interrupted'
                ) as has_interrupted_sessions
             from workspaces w
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
        let closed_sessions = self.sessions_for_workspace(workspace_id, SessionState::Closed)?;

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
            );",
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
                transport: session_transport_from_str(&row.get::<_, String>(2)?),
                target_label: row.get(3)?,
                last_cwd: row.get(4)?,
                close_reason: row
                    .get::<_, Option<String>>(5)?
                    .as_deref()
                    .map(close_reason_from_str)
                    .unwrap_or(CloseReason::UserClosed),
            })
        })?;

        rows.collect()
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
        let workspace_id: String = self.conn.query_row(
            "select workspace_id from sessions where id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        self.touch_workspace(&workspace_id)
    }
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

fn session_transport_from_str(value: &str) -> SessionTransport {
    match value {
        "local" => SessionTransport::Local,
        "ssh" => SessionTransport::Ssh,
        other => panic!("unknown session transport: {other}"),
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

fn close_reason_from_str(value: &str) -> CloseReason {
    match value {
        "user_closed" => CloseReason::UserClosed,
        "process_exited" => CloseReason::ProcessExited,
        "ssh_disconnected" => CloseReason::SshDisconnected,
        "app_crashed" => CloseReason::AppCrashed,
        "host_quit" => CloseReason::HostQuit,
        other => panic!("unknown close reason: {other}"),
    }
}
