use rusqlite::{params, Connection};

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
        let updated_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_secs() as i64;
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
            "select id, name, updated_at
             from workspaces
             order by updated_at desc, rowid desc",
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
                id text primary key not null,
                name text not null,
                note_body text not null,
                updated_at integer not null,
                last_opened_at integer not null
            );",
        )
    }
}
