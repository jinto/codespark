#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("invalid data in column `{column}`: {message}")]
    InvalidData { column: String, message: String },
}
