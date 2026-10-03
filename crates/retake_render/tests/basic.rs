//! End to end: render the cuts fixture (image with Ken Burns, trimmed clip,
//! letterboxed image, clip that ends early) and probe the MP4 with ffprobe.
//!
//! Needs `ffmpeg` and `ffprobe` on PATH (the Nix shell has them).

use std::path::{Path, PathBuf};
use std::process::Command;

use retake_render::render::{self, Options};
use retake_render::spec::Spec;
use retake_render::{timeline, Error};
use serde_json::{json, Value};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn out_dir(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// cuts.json with every scene cut to 300 ms so the test renders quickly.
/// The last scene starts 100 ms before its clip ends, so it must hold the last frame.
fn short_cuts() -> Value {
    let path = repo_root().join("fixtures/specs/cuts.json");
    let mut spec: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let scenes = spec["scenes"].as_array_mut().unwrap();
    for scene in scenes.iter_mut() {
        scene["duration_ms"] = json!(300);
    }
    scenes[3]["visual"]["trim_start_ms"] = json!(5900);
    spec
}

fn options(output: PathBuf) -> Options {
    Options {
        output,
        base_dir: repo_root(),
    }
}

fn probe(video: &Path) -> Value {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-select_streams", "v:0", "-show_entries"])
        .arg("stream=width,height,codec_name,pix_fmt,r_frame_rate,nb_frames")
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

#[test]
fn basic_renders_every_visual_type_to_a_1080x1920_mp4() {
    let spec = Spec::from_json(&short_cuts().to_string()).unwrap();
    let expected_frames = timeline::plan(&spec).total_frames;
    assert_eq!(expected_frames, 36); // 4 scenes x 9 frames

    let output = out_dir("basic").join("cuts.mp4");
    let mut last_progress = (0, 0);
    render::render(&spec, &options(output.clone()), &mut |done, total| {
        last_progress = (done, total);
    })
    .expect("render succeeds");

    assert_eq!(last_progress, (36, 36));
    let probed = probe(&output);
    let stream = &probed["streams"][0];
    assert_eq!(stream["width"], 1080);
    assert_eq!(stream["height"], 1920);
    assert_eq!(stream["codec_name"], "h264");
    assert_eq!(stream["pix_fmt"], "yuv420p");
    assert_eq!(stream["r_frame_rate"], "30/1");
    assert_eq!(stream["nb_frames"], expected_frames.to_string());
}

#[test]
fn basic_missing_asset_fails_before_writing_anything() {
    let mut value = short_cuts();
    value["assets"]["img-sea"]["uri"] = json!("file://fixtures/media/does-not-exist.jpg");
    let spec = Spec::from_json(&value.to_string()).unwrap();

    let output = out_dir("basic-missing").join("never.mp4");
    let _ = std::fs::remove_file(&output);
    let err = render::render(&spec, &options(output.clone()), &mut |_, _| {}).unwrap_err();

    assert!(
        matches!(err, Error::Asset { ref id, .. } if id == "img-sea"),
        "{err}"
    );
    assert!(err.to_string().contains("does-not-exist.jpg"), "{err}");
    assert!(
        !output.exists(),
        "the encoder must not start when an asset is missing"
    );
}

#[test]
fn basic_rejects_store_uris_for_now() {
    let mut value = short_cuts();
    value["assets"]["img-sea"]["uri"] = json!("store://assets/sea.jpg");
    let spec = Spec::from_json(&value.to_string()).unwrap();

    let output = out_dir("basic-store").join("never.mp4");
    let err = render::render(&spec, &options(output), &mut |_, _| {}).unwrap_err();
    assert!(err.to_string().contains("file://"), "{err}");
}

#[test]
fn basic_cli_prints_progress_and_done() {
    let dir = out_dir("basic-cli");
    let spec_path = dir.join("short-cuts.json");
    std::fs::write(&spec_path, short_cuts().to_string()).unwrap();
    let output = dir.join("cli.mp4");

    let out = Command::new(env!("CARGO_BIN_EXE_retake_render"))
        .current_dir(repo_root())
        .arg(&spec_path)
        .arg("-o")
        .arg(&output)
        .output()
        .expect("binary runs");

    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "stdout:\n{stdout}\nstderr:\n{stderr}");
    assert!(stdout.contains("progress 36/36"), "{stdout}");
    assert!(
        stdout
            .trim_end()
            .ends_with(&format!("done {}", output.display())),
        "{stdout}"
    );
    assert!(output.is_file());
}

#[test]
fn basic_cli_reports_errors_on_stderr_with_exit_code_1() {
    let out = Command::new(env!("CARGO_BIN_EXE_retake_render"))
        .arg("no/such/spec.json")
        .output()
        .expect("binary runs");

    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.starts_with("error:"), "{stderr}");
    assert!(stderr.contains("no/such/spec.json"), "{stderr}");
}
