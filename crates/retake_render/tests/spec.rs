//! The renderer must accept the same example and fixture specs as `Retake.Spec`
//! (F01) and reject broken ones (decision D15).

use std::path::{Path, PathBuf};

use retake_render::spec::{self, Spec};
use serde_json::{json, Value};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn json_files(dir: &str) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(repo_root().join(dir))
        .unwrap_or_else(|e| panic!("cannot read {dir}: {e}"))
        .map(|entry| entry.expect("dir entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    files
}

fn minimal() -> Value {
    let path = repo_root().join("spec/examples/minimal.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("read minimal.json")).unwrap()
}

fn parse(value: &Value) -> Result<Spec, retake_render::Error> {
    Spec::from_json(&value.to_string())
}

#[test]
fn spec_accepts_every_example() {
    let files = json_files("spec/examples");
    assert!(!files.is_empty());
    for path in files {
        spec::load(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    }
}

#[test]
fn spec_accepts_every_fixture() {
    let files = json_files("fixtures/specs");
    assert!(!files.is_empty());
    for path in files {
        spec::load(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    }
}

#[test]
fn spec_rejects_missing_file() {
    let err = spec::load(Path::new("no/such/spec.json")).unwrap_err();
    assert!(err.to_string().contains("no/such/spec.json"), "{err}");
}

#[test]
fn spec_rejects_invalid_json() {
    let err = Spec::from_json("{ not json").unwrap_err();
    assert!(err.to_string().starts_with("invalid spec:"), "{err}");
}

#[test]
fn spec_rejects_missing_required_field() {
    let mut spec = minimal();
    spec.as_object_mut().unwrap().remove("title");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("title"), "{err}");
}

#[test]
fn spec_rejects_unknown_field() {
    let mut spec = minimal();
    spec["extra"] = json!(1);
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("extra"), "{err}");
}

#[test]
fn spec_rejects_unknown_enum_value() {
    let mut spec = minimal();
    spec["scenes"][0]["visual"]["fit"] = json!("stretch");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("stretch"), "{err}");
}

#[test]
fn spec_rejects_wrong_type() {
    let mut spec = minimal();
    spec["scenes"][0]["duration_ms"] = json!("long");
    assert!(parse(&spec).is_err());
}

#[test]
fn spec_rejects_unsupported_version() {
    let mut spec = minimal();
    spec["spec_version"] = json!("0.3");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("spec_version"), "{err}");
}

#[test]
fn spec_rejects_the_previous_version() {
    // Elixir migrates 0.1 specs before rendering; the renderer only reads the current format.
    let mut spec = minimal();
    spec["spec_version"] = json!("0.1");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("spec_version"), "{err}");
}

#[test]
fn spec_accepts_an_image_prompt() {
    let mut spec = minimal();
    spec["scenes"][0]["intent"]["image_prompt"] = json!("A dim room, vertical shot.");
    let parsed = parse(&spec).expect("image_prompt is part of the intent");
    assert_eq!(
        parsed.scenes[0].intent.image_prompt.as_deref(),
        Some("A dim room, vertical shot.")
    );
}

#[test]
fn spec_rejects_fps_outside_the_allowed_set() {
    let mut spec = minimal();
    spec["output"]["fps"] = json!(60);
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("fps"), "{err}");
}

#[test]
fn spec_rejects_scene_with_unknown_asset() {
    let mut spec = minimal();
    spec["scenes"][0]["visual"]["asset"] = json!("nope");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("nope"), "{err}");
}

#[test]
fn spec_rejects_audio_asset_as_visual() {
    let mut spec = minimal();
    spec["scenes"][0]["visual"]["asset"] = json!("vo-1");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("audio"), "{err}");
}
