#[derive(Debug, Clone, PartialEq, Eq)]
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
            lines: lines.iter().map(|line| (*line).to_owned()).collect(),
        }
    }

    pub fn empty() -> Self {
        Self {
            cols: 0,
            rows: 0,
            lines: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotKind {
    Checkpoint,
    Final,
}

impl SnapshotKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Checkpoint => "checkpoint",
            Self::Final => "final",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NewSnapshot {
    pub session_id: String,
    pub kind: SnapshotKind,
    pub cwd: Option<String>,
    pub grid: TerminalGrid,
}
