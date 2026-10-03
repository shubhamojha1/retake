/// Everything that can stop a render. Messages are written for the person reading
/// the terminal (or, later, the Elixir side reading the Port's stderr).
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("cannot read {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },

    #[error("invalid spec: {0}")]
    Spec(String),

    #[error("asset {id:?}: {message}")]
    Asset { id: String, message: String },

    #[error("ffmpeg: {0}")]
    Ffmpeg(String),

    #[error(transparent)]
    Io(#[from] std::io::Error),
}
