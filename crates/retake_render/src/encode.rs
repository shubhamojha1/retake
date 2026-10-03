//! Encoding: raw RGBA frames are piped into an FFmpeg child process that writes
//! the H.264 MP4 (decision D10).

use std::io::Write;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};

use crate::Error;

pub struct Encoder {
    child: Child,
    stdin: Option<ChildStdin>,
}

impl Encoder {
    pub fn start(output: &Path, width: u32, height: u32, fps: u32) -> Result<Encoder, Error> {
        if let Some(dir) = output.parent() {
            std::fs::create_dir_all(dir)?;
        }

        // ponytail: veryfast/crf 20, no determinism flags yet; F06 pins threads and bitexact.
        let mut child = Command::new("ffmpeg")
            .args([
                "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s",
            ])
            .arg(format!("{width}x{height}"))
            .arg("-r")
            .arg(fps.to_string())
            .args([
                "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "veryfast",
            ])
            .args([
                "-crf",
                "20",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
            ])
            .arg(output)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| {
                Error::Ffmpeg(format!(
                    "cannot start ffmpeg: {e} (is it installed and on PATH?)"
                ))
            })?;
        let stdin = child.stdin.take();

        Ok(Encoder { child, stdin })
    }

    /// Writes one raw RGBA frame.
    pub fn write_frame(&mut self, rgba: &[u8]) -> Result<(), Error> {
        let stdin = self.stdin.as_mut().expect("encoder is still open");
        stdin
            .write_all(rgba)
            .map_err(|e| Error::Ffmpeg(format!("the encoder stopped accepting frames: {e}")))
    }

    /// Closes the pipe and waits for FFmpeg to finish writing the file.
    pub fn finish(mut self) -> Result<(), Error> {
        drop(self.stdin.take());
        let status = self.child.wait()?;
        if status.success() {
            Ok(())
        } else {
            Err(Error::Ffmpeg(format!("the encoder exited with {status}")))
        }
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        // Only matters when a render fails half way: don't leave FFmpeg waiting for frames.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
