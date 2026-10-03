//! Loading visuals: still images are decoded once, video clips are streamed
//! frame by frame from an FFmpeg child process (decision D10).

use std::io::{self, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};

use tiny_skia::{IntSize, Pixmap};

use crate::Error;

fn asset_error(id: &str, message: impl Into<String>) -> Error {
    Error::Asset {
        id: id.to_string(),
        message: message.into(),
    }
}

/// Turns an asset uri into a file path. `file://` paths are relative to
/// `base_dir` (the repo root when run through `just render`); absolute paths
/// are used as they are.
pub fn resolve(id: &str, uri: &str, base_dir: &Path) -> Result<PathBuf, Error> {
    match uri.strip_prefix("file://") {
        Some(path) => Ok(base_dir.join(path)),
        None => Err(asset_error(
            id,
            format!("only file:// uris are supported by the standalone renderer, got {uri:?}"),
        )),
    }
}

/// Decodes an image into a premultiplied RGBA pixmap, as tiny-skia expects.
pub fn load_image(id: &str, path: &Path) -> Result<Pixmap, Error> {
    let rgba = image::open(path)
        .map_err(|e| asset_error(id, format!("cannot decode {}: {e}", path.display())))?
        .to_rgba8();
    let (width, height) = rgba.dimensions();
    let mut data = rgba.into_raw();

    for pixel in data.chunks_exact_mut(4) {
        let alpha = u32::from(pixel[3]);
        if alpha != 255 {
            for channel in &mut pixel[..3] {
                *channel = ((u32::from(*channel) * alpha + 127) / 255) as u8;
            }
        }
    }

    let size =
        IntSize::from_wh(width, height).ok_or_else(|| asset_error(id, "image has zero size"))?;
    Pixmap::from_vec(data, size).ok_or_else(|| asset_error(id, "image buffer has the wrong size"))
}

/// A video clip read through FFmpeg: resampled to the output frame rate and
/// scaled to the size the spec declares, starting at `trim_start_ms`. When the
/// clip ends before the scene does, the last frame is held (decision D13).
pub struct VideoSource {
    id: String,
    child: Child,
    stdout: BufReader<ChildStdout>,
    buffer: Vec<u8>,
    frame: Pixmap,
    has_frame: bool,
    ended: bool,
}

impl VideoSource {
    pub fn open(
        id: &str,
        path: &Path,
        trim_start_ms: u64,
        fps: u32,
        width: u32,
        height: u32,
    ) -> Result<VideoSource, Error> {
        let frame =
            Pixmap::new(width, height).ok_or_else(|| asset_error(id, "video has zero size"))?;
        let seek = format!("{:.3}", trim_start_ms as f64 / 1000.0);
        let filter = format!("fps={fps},scale={width}:{height}");

        let mut child = Command::new("ffmpeg")
            .args(["-v", "error", "-nostdin", "-ss"])
            .arg(&seek)
            .arg("-i")
            .arg(path)
            .args(["-an", "-vf"])
            .arg(&filter)
            .args(["-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| {
                Error::Ffmpeg(format!(
                    "cannot start ffmpeg: {e} (is it installed and on PATH?)"
                ))
            })?;
        let stdout = child.stdout.take().expect("stdout is piped");

        Ok(VideoSource {
            id: id.to_string(),
            child,
            stdout: BufReader::with_capacity(1 << 20, stdout),
            buffer: vec![0; width as usize * height as usize * 4],
            frame,
            has_frame: false,
            ended: false,
        })
    }

    pub fn size(&self) -> (u32, u32) {
        (self.frame.width(), self.frame.height())
    }

    /// The next frame, or the last one again once the clip has ended.
    pub fn next_frame(&mut self) -> Result<&Pixmap, Error> {
        if !self.ended {
            match self.stdout.read_exact(&mut self.buffer) {
                Ok(()) => {
                    self.frame.data_mut().copy_from_slice(&self.buffer);
                    self.has_frame = true;
                }
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => self.ended = true,
                Err(e) => {
                    return Err(Error::Ffmpeg(format!(
                        "reading frames of asset {:?}: {e}",
                        self.id
                    )))
                }
            }
        }
        if self.has_frame {
            Ok(&self.frame)
        } else {
            Err(asset_error(
                &self.id,
                "video has no frames at trim_start_ms",
            ))
        }
    }
}

impl Drop for VideoSource {
    fn drop(&mut self) {
        // The scene may end before the clip does; don't leave FFmpeg blocked on a full pipe.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
