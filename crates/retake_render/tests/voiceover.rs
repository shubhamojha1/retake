//! F05a: each scene's voice-over is mixed into the MP4 at scene start + offset_ms.
//!
//! The fixture voice-overs are beeps (400 ms beep, 100 ms gap, per word), so the
//! start of every beep is known exactly and `silencedetect` can find it.
//! Needs `ffmpeg` and `ffprobe` on PATH (the Nix shell has them).

use std::path::{Path, PathBuf};
use std::process::Command;

use retake_render::render::{self, Options};
use retake_render::spec::Spec;
use serde_json::{json, Value};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn out_dir(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn fixture(name: &str) -> Value {
    let path = repo_root().join("fixtures/specs").join(name);
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn render_to(spec: &Value, output: &Path) {
    let spec = Spec::from_json(&spec.to_string()).unwrap();
    let options = Options {
        output: output.to_path_buf(),
        base_dir: repo_root(),
    };
    render::render(&spec, &options, &mut |_, _| {}).expect("render succeeds");
}

/// ffprobe the first stream of `kind` ("a" or "v"); `streams` is empty if there is none.
fn probe(video: &Path, kind: &str) -> Value {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-select_streams"])
        .arg(format!("{kind}:0"))
        .args([
            "-show_entries",
            "stream=codec_name,sample_rate,channels,duration",
        ])
        .args(["-of", "json"])
        .arg(video)
        .output()
        .expect("ffprobe runs");
    assert!(
        out.status.success(),
        "ffprobe failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("ffprobe prints json")
}

/// The number after `key` on a line, e.g. `silence_end: 0.3 | ...` with key `silence_end: `.
fn number_after(line: &str, key: &str) -> Option<f64> {
    line.split(key)
        .nth(1)?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

/// Times (seconds) at which sound stops (`silence_start`) and starts (`silence_end`).
fn silence_events(video: &Path) -> (Vec<f64>, Vec<f64>) {
    let out = Command::new("ffmpeg")
        .args(["-hide_banner", "-nostdin", "-i"])
        .arg(video)
        .args([
            "-vn",
            "-af",
            "silencedetect=noise=-30dB:d=0.05",
            "-f",
            "null",
            "-",
        ])
        .output()
        .expect("ffmpeg runs");
    let log = String::from_utf8_lossy(&out.stderr);
    let starts = log
        .lines()
        .filter_map(|l| number_after(l, "silence_start: "))
        .collect();
    let ends = log
        .lines()
        .filter_map(|l| number_after(l, "silence_end: "))
        .collect();
    (starts, ends)
}

fn near(actual: f64, expected: f64) -> bool {
    (actual - expected).abs() < 0.06
}

#[test]
fn voiceover_is_mixed_in_at_scene_start_plus_offset() {
    // minimal.json: one scene, voice-over at offset_ms 300; the first beep is 0-400 ms of the file.
    let output = out_dir("voiceover").join("minimal.mp4");
    render_to(&fixture("minimal.json"), &output);

    let audio = probe(&output, "a");
    let stream = &audio["streams"][0];
    assert_eq!(stream["codec_name"], "aac", "{audio}");
    assert_eq!(stream["sample_rate"], "48000");
    assert_eq!(stream["channels"], 2);

    let video = probe(&output, "v");
    let seconds = |v: &Value| {
        v["streams"][0]["duration"]
            .as_str()
            .unwrap()
            .parse::<f64>()
            .unwrap()
    };
    assert!(
        (seconds(&audio) - seconds(&video)).abs() < 0.1,
        "audio {} s vs video {} s",
        seconds(&audio),
        seconds(&video)
    );

    let (starts, ends) = silence_events(&output);
    assert!(
        ends.iter().any(|&t| near(t, 0.3)),
        "sound should start at 0.3 s: ends {ends:?}"
    );
    assert!(
        starts.iter().any(|&t| near(t, 0.7)),
        "first beep should stop at 0.7 s: starts {starts:?}"
    );
}

#[test]
fn voiceover_of_a_later_scene_starts_after_the_scenes_before_it() {
    // multi.json scenes last 5000, 4500, 4200 ms and join as cuts for now (crossfades are F04), so the
    // voice-overs start at 5000 + 200 and 9500 + 200 ms.
    let output = out_dir("voiceover").join("multi.mp4");
    render_to(&fixture("multi.json"), &output);

    let (_, ends) = silence_events(&output);
    assert!(
        ends.iter().any(|&t| near(t, 0.2)),
        "scene 1 voice-over at 0.2 s: {ends:?}"
    );
    assert!(
        ends.iter().any(|&t| near(t, 5.2)),
        "scene 2 voice-over at 5.2 s: {ends:?}"
    );
    assert!(
        ends.iter().any(|&t| near(t, 9.7)),
        "scene 3 voice-over at 9.7 s: {ends:?}"
    );
}

#[test]
fn voiceover_absent_means_no_audio_stream() {
    let mut spec = fixture("minimal.json");
    spec["scenes"][0]["voiceover"] = json!(null);
    let output = out_dir("voiceover").join("silent.mp4");
    render_to(&spec, &output);

    assert_eq!(probe(&output, "a")["streams"], json!([]));
}
