//! Maps spec milliseconds to output frames.
//!
//! Scene *boundaries* are rounded to the nearest frame (half up), not scene
//! durations, so rounding error never accumulates (`spec/SPEC.md`, timing model).
//! Until F04, every transition is treated as a cut (decision D14).

use crate::spec::Spec;

/// Milliseconds to frames at `fps`, rounded to the nearest frame, half up.
pub fn ms_to_frame(ms: u64, fps: u32) -> u64 {
    (ms * u64::from(fps) + 500) / 1000
}

/// One scene's place on the output timeline. Frames are `start_frame..end_frame`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScenePlan {
    pub index: usize,
    pub start_frame: u64,
    pub end_frame: u64,
}

impl ScenePlan {
    pub fn frames(&self) -> u64 {
        self.end_frame - self.start_frame
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timeline {
    pub scenes: Vec<ScenePlan>,
    pub total_frames: u64,
}

pub fn plan(spec: &Spec) -> Timeline {
    let fps = spec.output.fps;
    let mut scenes = Vec::with_capacity(spec.scenes.len());
    let mut start_ms = 0;
    for (index, scene) in spec.scenes.iter().enumerate() {
        let end_ms = start_ms + scene.duration_ms;
        scenes.push(ScenePlan {
            index,
            start_frame: ms_to_frame(start_ms, fps),
            end_frame: ms_to_frame(end_ms, fps),
        });
        start_ms = end_ms;
    }
    let total_frames = scenes.last().map_or(0, |s| s.end_frame);
    Timeline {
        scenes,
        total_frames,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL: &str = include_str!("../../../fixtures/specs/minimal.json");

    fn spec_with_durations(durations: &[u64]) -> Spec {
        let mut spec = Spec::from_json(MINIMAL).expect("minimal fixture parses");
        let template = spec.scenes[0].clone();
        spec.scenes = durations
            .iter()
            .enumerate()
            .map(|(i, &d)| {
                let mut scene = template.clone();
                scene.id = format!("s{i}");
                scene.duration_ms = d;
                scene
            })
            .collect();
        spec
    }

    #[test]
    fn rounds_to_nearest_frame_half_up() {
        assert_eq!(ms_to_frame(4000, 30), 120);
        assert_eq!(ms_to_frame(1000, 24), 24);
        assert_eq!(ms_to_frame(16, 30), 0); // 0.48 frames
        assert_eq!(ms_to_frame(17, 30), 1); // 0.51 frames
        assert_eq!(ms_to_frame(50, 10), 1); // exactly half rounds up
    }

    #[test]
    fn one_scene_covers_its_duration() {
        let timeline = plan(&spec_with_durations(&[4000]));
        assert_eq!(timeline.total_frames, 120);
        assert_eq!(
            timeline.scenes,
            vec![ScenePlan {
                index: 0,
                start_frame: 0,
                end_frame: 120
            }]
        );
    }

    #[test]
    fn scenes_are_contiguous_and_cover_the_total() {
        let timeline = plan(&spec_with_durations(&[2000, 3000, 1500]));
        let starts: Vec<u64> = timeline.scenes.iter().map(|s| s.start_frame).collect();
        let ends: Vec<u64> = timeline.scenes.iter().map(|s| s.end_frame).collect();
        assert_eq!(starts, vec![0, 60, 150]);
        assert_eq!(ends, vec![60, 150, 195]);
        assert_eq!(timeline.total_frames, 195);
    }

    #[test]
    fn boundary_rounding_does_not_drift() {
        // 3 x 1017 ms at 30 fps: rounding each duration would give 3 x 31 = 93
        // frames; rounding the boundaries gives round(3051 * 30 / 1000) = 92.
        let timeline = plan(&spec_with_durations(&[1017, 1017, 1017]));
        assert_eq!(timeline.total_frames, ms_to_frame(3051, 30));
        assert_eq!(timeline.total_frames, 92);
        let frames: u64 = timeline.scenes.iter().map(ScenePlan::frames).sum();
        assert_eq!(frames, timeline.total_frames);
    }
}
