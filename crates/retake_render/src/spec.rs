//! The video spec (`spec/SPEC.md`) as strict typed structs.
//!
//! Unknown fields and wrong types are rejected at parse time, and enums are
//! checked. Numeric ranges and the semantic rules belong to `Retake.Spec` in the
//! Elixir app (decision D15); `Spec::check` only covers what the renderer cannot
//! proceed without.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::Error;

pub const SUPPORTED_VERSION: &str = "0.1";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    pub spec_version: String,
    pub id: String,
    pub title: String,
    pub brief: Brief,
    pub output: Output,
    pub assets: BTreeMap<String, Asset>,
    pub scenes: Vec<Scene>,
    pub captions: Captions,
    pub music: Option<Music>,
    pub loudness: Option<Loudness>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Brief {
    pub prompt: String,
    pub target_duration_ms: u64,
    pub language: String,
    pub tone: Option<String>,
    pub audience: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Output {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub background: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AssetKind {
    Image,
    Video,
    Audio,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Asset {
    pub kind: AssetKind,
    pub uri: String,
    pub content_hash: String,
    pub media: Media,
    // Provenance and licence are for people and the pipeline, not the renderer.
    pub provenance: Value,
    pub license: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Media {
    pub duration_ms: Option<u64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u8>,
    pub mime: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scene {
    pub id: String,
    pub intent: Intent,
    pub duration_ms: u64,
    pub visual: Visual,
    pub voiceover: Option<Voiceover>,
    pub overlays: Option<Vec<Overlay>>,
    pub transition_in: Option<Transition>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Intent {
    pub narration: String,
    pub visual_query: String,
    pub on_screen_text: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Visual {
    pub asset: String,
    pub fit: Fit,
    pub trim_start_ms: Option<u64>,
    pub motion: Option<Motion>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fit {
    Cover,
    Contain,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Motion {
    pub from: FrameTransform,
    pub to: FrameTransform,
    pub easing: Option<Easing>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FrameTransform {
    pub scale: f64,
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Easing {
    Linear,
    EaseInOut,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Voiceover {
    pub asset: String,
    pub offset_ms: u64,
    pub gain_db: Option<f64>,
    pub words: Vec<Word>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Word {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Overlay {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub position: Position,
    pub style: Option<TextStyle>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Position {
    Top,
    Center,
    Bottom,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TextStyle {
    pub font_family: Option<String>,
    pub font_weight: Option<u16>,
    pub font_size_px: Option<u32>,
    pub color: Option<String>,
    pub stroke_color: Option<String>,
    pub stroke_px: Option<u32>,
    pub background: Option<String>,
    pub uppercase: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Transition {
    pub kind: TransitionKind,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransitionKind {
    Cut,
    Crossfade,
    FadeThroughBlack,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Captions {
    pub enabled: bool,
    pub style: CaptionStyle,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptionStyle {
    pub mode: CaptionMode,
    pub max_words_per_line: u32,
    pub max_lines: u32,
    pub position: CaptionPosition,
    pub highlight_color: Option<String>,
    pub text: TextStyle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptionMode {
    Phrase,
    WordHighlight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptionPosition {
    Center,
    LowerThird,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Music {
    pub asset: String,
    pub gain_db: f64,
    pub fade_in_ms: Option<u64>,
    pub fade_out_ms: Option<u64>,
    pub ducking: Ducking,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ducking {
    pub enabled: bool,
    pub reduction_db: f64,
    pub attack_ms: Option<u64>,
    pub release_ms: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Loudness {
    pub integrated_lufs: f64,
    pub true_peak_dbtp: f64,
}

impl Spec {
    /// Parses and checks a spec from JSON text.
    pub fn from_json(json: &str) -> Result<Spec, Error> {
        let spec: Spec = serde_json::from_str(json).map_err(|e| Error::Spec(e.to_string()))?;
        spec.check()?;
        Ok(spec)
    }

    /// Sanity checks the renderer needs to proceed. Not a replacement for
    /// `Retake.Spec` (D15).
    pub fn check(&self) -> Result<(), Error> {
        let bad = |msg: String| Err(Error::Spec(msg));

        if self.spec_version != SUPPORTED_VERSION {
            return bad(format!(
                "spec_version {:?} is not supported (expected {SUPPORTED_VERSION:?})",
                self.spec_version
            ));
        }
        if (self.output.width, self.output.height) != (1080, 1920) {
            return bad(format!(
                "output must be 1080x1920, got {}x{}",
                self.output.width, self.output.height
            ));
        }
        if ![24, 25, 30].contains(&self.output.fps) {
            return bad(format!(
                "output.fps must be 24, 25 or 30, got {}",
                self.output.fps
            ));
        }
        if self.scenes.is_empty() {
            return bad("spec has no scenes".to_string());
        }
        for scene in &self.scenes {
            match self.assets.get(&scene.visual.asset) {
                None => {
                    return bad(format!(
                        "scene {:?} uses asset {:?}, which is not in assets",
                        scene.id, scene.visual.asset
                    ))
                }
                Some(asset) if asset.kind == AssetKind::Audio => {
                    return bad(format!(
                        "scene {:?} uses audio asset {:?} as its visual",
                        scene.id, scene.visual.asset
                    ))
                }
                Some(_) => {}
            }
        }
        Ok(())
    }
}

/// Reads, parses and checks a spec file.
pub fn load(path: &Path) -> Result<Spec, Error> {
    let json = std::fs::read_to_string(path).map_err(|source| Error::Read {
        path: path.display().to_string(),
        source,
    })?;
    Spec::from_json(&json)
}
