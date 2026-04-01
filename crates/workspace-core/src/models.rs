#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub live_sessions: i64,
    pub recently_closed_sessions: i64,
    pub has_interrupted_sessions: bool,
    pub updated_at: i64,
}
