//! Retake renderer: reads a video spec, writes an MP4.
//!
//! The renderer version is part of the determinism contract (AGENTS.md rule 3):
//! same spec + same asset bytes + same renderer version + same pinned FFmpeg
//! gives identical output.

pub mod audio;
pub mod compose;
pub mod encode;
pub mod error;
pub mod media;
pub mod render;
pub mod spec;
pub mod timeline;

pub use error::Error;

/// Version of this renderer, taken from Cargo.toml.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_semver_like() {
        let parts: Vec<&str> = version().split('.').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts.iter().all(|p| p.parse::<u32>().is_ok()));
    }
}
