//! The render loop: for every frame of every scene, draw the visual and pipe the
//! frame to the encoder.

use std::path::PathBuf;

use tiny_skia::{Color, Pixmap};

use crate::audio;
use crate::compose;
use crate::encode::Encoder;
use crate::media::{self, VideoSource};
use crate::spec::{AssetKind, Spec, TransitionKind};
use crate::timeline;
use crate::Error;

pub struct Options {
    /// Where the MP4 is written.
    pub output: PathBuf,
    /// `file://` asset paths are relative to this directory.
    pub base_dir: PathBuf,
}

enum Source {
    Image(Pixmap),
    Video(Box<VideoSource>),
}

/// Parts of the spec this renderer does not draw yet (decision D14). Each line
/// goes away when the feature that implements it lands.
pub fn unsupported_features(spec: &Spec) -> Vec<String> {
    let mut warnings = Vec::new();
    if spec.music.is_some() {
        warnings.push("music is not rendered yet (F05b)");
    }
    if spec.captions.enabled {
        warnings.push("captions are not rendered yet (F04)");
    }
    if spec
        .scenes
        .iter()
        .any(|s| s.overlays.as_ref().is_some_and(|o| !o.is_empty()))
    {
        warnings.push("text overlays are not rendered yet (F04)");
    }
    if spec.scenes.iter().any(|s| {
        s.transition_in
            .as_ref()
            .is_some_and(|t| t.kind != TransitionKind::Cut)
    }) {
        warnings.push("transitions other than cut are rendered as cuts (F04)");
    }
    warnings.into_iter().map(String::from).collect()
}

/// Renders the spec to `options.output`. `progress(done, total)` is called after every frame.
pub fn render(
    spec: &Spec,
    options: &Options,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<(), Error> {
    let (width, height, fps) = (spec.output.width, spec.output.height, spec.output.fps);

    let mut background = match spec.output.background.as_deref() {
        None => Color::BLACK,
        Some(hex) => compose::parse_color(hex).ok_or_else(|| {
            Error::Spec(format!(
                "output.background {hex:?} is not #RRGGBB or #RRGGBBAA"
            ))
        })?,
    };
    background.set_alpha(1.0);

    // Fail before starting the encoder if any visual is missing.
    let mut paths = Vec::with_capacity(spec.scenes.len());
    for scene in &spec.scenes {
        let asset = &spec.assets[&scene.visual.asset];
        let path = media::resolve(&scene.visual.asset, &asset.uri, &options.base_dir)?;
        if !path.is_file() {
            return Err(Error::Asset {
                id: scene.visual.asset.clone(),
                message: format!("file not found: {}", path.display()),
            });
        }
        paths.push(path);
    }

    let plan = timeline::plan(spec);
    let voiceovers = audio::clips(spec, &plan, &options.base_dir)?;
    let total_secs = plan.total_frames as f64 / f64::from(fps);

    let mut frame = Pixmap::new(width, height)
        .ok_or_else(|| Error::Spec("output size must not be zero".to_string()))?;
    let mut encoder = Encoder::start(&options.output, width, height, fps, &voiceovers, total_secs)?;
    let mut done = 0;

    for scene_plan in &plan.scenes {
        let scene = &spec.scenes[scene_plan.index];
        let id = &scene.visual.asset;
        let asset = &spec.assets[id];
        let path = &paths[scene_plan.index];

        let mut source = match asset.kind {
            AssetKind::Image => Source::Image(media::load_image(id, path)?),
            AssetKind::Video => {
                let (w, h) = match (asset.media.width, asset.media.height) {
                    (Some(w), Some(h)) => (w, h),
                    _ => {
                        return Err(Error::Asset {
                            id: id.clone(),
                            message: "video asset needs media.width and media.height".to_string(),
                        })
                    }
                };
                let trim = scene.visual.trim_start_ms.unwrap_or(0);
                Source::Video(Box::new(VideoSource::open(id, path, trim, fps, w, h)?))
            }
            AssetKind::Audio => unreachable!("Spec::check rejects audio visuals"),
        };

        let frames = scene_plan.frames();
        for i in 0..frames {
            let view = compose::motion_at(scene.visual.motion.as_ref(), i, frames);
            let (size, visual) = match &mut source {
                Source::Image(pixmap) => ((pixmap.width(), pixmap.height()), pixmap.as_ref()),
                Source::Video(video) => {
                    let size = video.size();
                    (size, video.next_frame()?.as_ref())
                }
            };

            frame.fill(background);
            let placement = compose::place(size, (width, height), scene.visual.fit, view);
            compose::draw_visual(&mut frame, visual, placement);
            encoder.write_frame(frame.data())?;

            done += 1;
            progress(done, plan.total_frames);
        }
    }

    encoder.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    const CUTS: &str = include_str!("../../../fixtures/specs/cuts.json");
    const MULTI: &str = include_str!("../../../fixtures/specs/multi.json");

    #[test]
    fn cuts_only_spec_has_nothing_unsupported() {
        let spec = Spec::from_json(CUTS).unwrap();
        assert_eq!(unsupported_features(&spec), Vec::<String>::new());
    }

    #[test]
    fn multi_spec_lists_every_unbuilt_feature() {
        let spec = Spec::from_json(MULTI).unwrap();
        let warnings = unsupported_features(&spec).join("\n");
        for needle in ["music", "captions", "overlays", "transitions"] {
            assert!(
                warnings.contains(needle),
                "missing {needle:?} in:\n{warnings}"
            );
        }
    }

    #[test]
    fn voiceover_is_no_longer_reported_as_unsupported() {
        let spec = Spec::from_json(MULTI).unwrap();
        let warnings = unsupported_features(&spec).join("\n");
        assert!(!warnings.contains("voice-over"), "{warnings}");
    }
}
