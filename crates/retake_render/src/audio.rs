//! Voice-over audio: where each clip sits on the output timeline, and the
//! FFmpeg filter graph that delays, levels and mixes them into one track.
//!
//! Music, ducking and the loudness pass are F05b.

use std::path::{Path, PathBuf};

use crate::media;
use crate::spec::{AssetKind, Spec};
use crate::timeline::Timeline;
use crate::Error;

/// One voice-over file placed on the output timeline.
#[derive(Debug, Clone, PartialEq)]
pub struct Clip {
    pub path: PathBuf,
    /// When the clip starts, in milliseconds from the start of the video.
    pub delay_ms: u64,
    pub gain_db: f64,
}

/// The voice-over clips of every scene that has one, in scene order. Fails if a
/// voice-over asset is missing, is not audio, or its file does not exist.
pub fn clips(spec: &Spec, plan: &Timeline, base_dir: &Path) -> Result<Vec<Clip>, Error> {
    let fps = u64::from(spec.output.fps);
    let mut clips = Vec::new();

    for scene_plan in &plan.scenes {
        let scene = &spec.scenes[scene_plan.index];
        let Some(voiceover) = &scene.voiceover else {
            continue;
        };
        let id = &voiceover.asset;
        let fail = |message: String| Error::Asset {
            id: id.clone(),
            message,
        };

        let asset = spec
            .assets
            .get(id)
            .ok_or_else(|| fail(format!("scene {:?} voice-over is not in assets", scene.id)))?;
        if asset.kind != AssetKind::Audio {
            return Err(fail(format!(
                "scene {:?} voice-over must be an audio asset",
                scene.id
            )));
        }
        let path = media::resolve(id, &asset.uri, base_dir)?;
        if !path.is_file() {
            return Err(fail(format!("file not found: {}", path.display())));
        }

        // Start from the frame the scene's picture starts on, so sound and picture agree.
        let scene_start_ms = (scene_plan.start_frame * 1000 + fps / 2) / fps;
        clips.push(Clip {
            path,
            delay_ms: scene_start_ms + voiceover.offset_ms,
            gain_db: voiceover.gain_db.unwrap_or(0.0),
        });
    }
    Ok(clips)
}

/// The `-filter_complex` graph for `clips`; its output is labelled `[aout]`.
///
/// Input 0 of the encoder is the raw video on stdin, so voice-over `n` (from 0)
/// is input `n + 1`. Each clip is resampled to 48 kHz stereo, levelled and
/// delayed; they are summed (`normalize=0`, so the level is not divided by the
/// number of clips) and padded or cut to exactly `total_secs`, the video length.
pub fn filter(clips: &[Clip], total_secs: f64) -> String {
    let mut parts: Vec<String> = clips
        .iter()
        .enumerate()
        .map(|(n, clip)| {
            let input = n + 1;
            format!(
                "[{input}:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,\
                 volume={gain:.2}dB,adelay={delay}:all=1[v{input}]",
                gain = clip.gain_db,
                delay = clip.delay_ms,
            )
        })
        .collect();

    let labels: String = (1..=clips.len())
        .map(|input| format!("[v{input}]"))
        .collect();
    parts.push(format!(
        "{labels}amix=inputs={count}:normalize=0:duration=longest,\
         apad=whole_dur={total_secs:.6},atrim=end={total_secs:.6}[aout]",
        count = clips.len(),
    ));
    parts.join(";")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline;

    const CUTS: &str = include_str!("../../../fixtures/specs/cuts.json");
    const MINIMAL: &str = include_str!("../../../fixtures/specs/minimal.json");
    const MULTI: &str = include_str!("../../../fixtures/specs/multi.json");

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    fn clips_of(json: &str) -> Result<Vec<Clip>, Error> {
        let spec = Spec::from_json(json).unwrap();
        clips(&spec, &timeline::plan(&spec), &repo_root())
    }

    #[test]
    fn voiceover_clips_start_at_scene_start_plus_offset() {
        // multi.json scenes last 5000, 4500, 4200 ms and join as cuts; every offset is 200 ms.
        let delays: Vec<u64> = clips_of(MULTI)
            .unwrap()
            .iter()
            .map(|c| c.delay_ms)
            .collect();
        assert_eq!(delays, vec![200, 5200, 9700]);
    }

    #[test]
    fn voiceover_clip_points_at_its_file_and_defaults_to_zero_gain() {
        let clips = clips_of(MINIMAL).unwrap();
        assert_eq!(clips.len(), 1);
        assert!(
            clips[0].path.ends_with("fixtures/media/vo-minimal.wav"),
            "{:?}",
            clips[0].path
        );
        assert_eq!(clips[0].delay_ms, 300);
        assert_eq!(clips[0].gain_db, 0.0);
    }

    #[test]
    fn voiceover_clips_are_empty_for_a_spec_without_voiceovers() {
        assert_eq!(clips_of(CUTS).unwrap(), vec![]);
    }

    #[test]
    fn voiceover_asset_must_be_audio() {
        let json = MINIMAL.replace(r#""asset": "vo-1""#, r#""asset": "img-sea""#);
        let err = clips_of(&json).unwrap_err();
        assert!(err.to_string().contains("audio"), "{err}");
    }

    #[test]
    fn voiceover_file_must_exist() {
        let json = MINIMAL.replace("vo-minimal.wav", "nope.wav");
        let err = clips_of(&json).unwrap_err();
        assert!(err.to_string().contains("nope.wav"), "{err}");
    }

    #[test]
    fn voiceover_filter_delays_levels_and_mixes_every_clip() {
        let clip = |ms, db| Clip {
            path: PathBuf::from("x.wav"),
            delay_ms: ms,
            gain_db: db,
        };
        let graph = filter(&[clip(200, 0.0), clip(5200, -3.0)], 13.7);

        assert!(graph.contains("[1:a]aresample=48000"), "{graph}");
        assert!(
            graph.contains("volume=0.00dB,adelay=200:all=1[v1]"),
            "{graph}"
        );
        assert!(graph.contains("[2:a]aresample=48000"), "{graph}");
        assert!(
            graph.contains("volume=-3.00dB,adelay=5200:all=1[v2]"),
            "{graph}"
        );
        assert!(
            graph.contains("[v1][v2]amix=inputs=2:normalize=0"),
            "{graph}"
        );
        assert!(
            graph.ends_with("apad=whole_dur=13.700000,atrim=end=13.700000[aout]"),
            "{graph}"
        );
    }
}
