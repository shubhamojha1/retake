//! `retake_render <spec.json> [-o <out.mp4>]`
//!
//! stdout (read by the Elixir side, decision D4): `progress <done>/<total>` and a
//! final `done <path>`. stderr: `warning: ...` lines and, on failure, `error: ...`
//! with exit code 1.

use std::path::PathBuf;
use std::process::ExitCode;

use retake_render::render::{self, Options};
use retake_render::spec;

const USAGE: &str = "usage: retake_render <spec.json> [-o <out.mp4>]";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut spec_path = None;
    let mut output = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-o" | "--output" => {
                output = Some(PathBuf::from(args.next().ok_or(USAGE)?));
            }
            "--version" => {
                println!("retake_render {}", retake_render::version());
                return Ok(());
            }
            _ if spec_path.is_none() => spec_path = Some(PathBuf::from(arg)),
            _ => return Err(USAGE.to_string()),
        }
    }
    let spec_path = spec_path.ok_or(USAGE)?;

    let spec = spec::load(&spec_path).map_err(|e| e.to_string())?;
    let output = match output {
        Some(path) => path,
        None => {
            if !spec
                .id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            {
                return Err(format!(
                    "spec id {:?} is not safe to use as a file name; pass -o",
                    spec.id
                ));
            }
            PathBuf::from(".retake/out").join(format!("{}.mp4", spec.id))
        }
    };

    for warning in render::unsupported_features(&spec) {
        eprintln!("warning: {warning}");
    }

    let options = Options {
        output: output.clone(),
        base_dir: std::env::current_dir().map_err(|e| e.to_string())?,
    };
    render::render(&spec, &options, &mut |done, total| {
        if done % 10 == 0 || done == total {
            println!("progress {done}/{total}");
        }
    })
    .map_err(|e| e.to_string())?;

    println!("done {}", output.display());
    Ok(())
}
