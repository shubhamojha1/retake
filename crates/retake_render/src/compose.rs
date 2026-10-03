//! Compositing for one output frame: where a visual lands (fit and Ken Burns
//! motion, `spec/SPEC.md` "Visual placement") and drawing it with tiny-skia.

use tiny_skia::{
    Color, FilterQuality, Paint, Pattern, Pixmap, PixmapRef, Rect, SpreadMode, Transform,
};

use crate::spec::{Easing, Fit, FrameTransform, Motion};

/// No zoom, no pan.
pub const IDENTITY: FrameTransform = FrameTransform {
    scale: 1.0,
    x: 0.0,
    y: 0.0,
};

/// Where a visual lands in the output frame: a uniform scale and the position
/// of its top-left corner, in output pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    pub scale: f64,
    pub x: f64,
    pub y: f64,
}

/// Places a `source`-sized visual in a `frame`-sized output.
///
/// `fit` gives the base scale (cover fills the frame, contain fits whole);
/// `view.scale` multiplies it. `view.x` and `view.y` pan: a positive `x` moves
/// the view toward the right edge of the visual by `x` times half the overflow,
/// so `x = 1` puts the visual's right edge on the frame's right edge.
pub fn place(source: (u32, u32), frame: (u32, u32), fit: Fit, view: FrameTransform) -> Placement {
    let (sw, sh) = (f64::from(source.0), f64::from(source.1));
    let (fw, fh) = (f64::from(frame.0), f64::from(frame.1));

    let base = match fit {
        Fit::Cover => (fw / sw).max(fh / sh),
        Fit::Contain => (fw / sw).min(fh / sh),
    };
    let scale = base * view.scale;
    let (dw, dh) = (sw * scale, sh * scale);

    // How far the drawn visual overflows each side of the frame.
    let overflow_x = (dw - fw).max(0.0) / 2.0;
    let overflow_y = (dh - fh).max(0.0) / 2.0;

    Placement {
        scale,
        x: (fw - dw) / 2.0 - view.x * overflow_x,
        y: (fh - dh) / 2.0 - view.y * overflow_y,
    }
}

/// The motion state at `frame_in_scene` of a scene `scene_frames` long: `from`
/// on the first frame, `to` on the last, shaped by the easing. No motion is
/// the identity transform.
pub fn motion_at(
    motion: Option<&Motion>,
    frame_in_scene: u64,
    scene_frames: u64,
) -> FrameTransform {
    let Some(motion) = motion else {
        return IDENTITY;
    };

    let t = if scene_frames > 1 {
        frame_in_scene as f64 / (scene_frames - 1) as f64
    } else {
        0.0
    };
    let t = match motion.easing.unwrap_or(Easing::Linear) {
        Easing::Linear => t,
        Easing::EaseInOut => t * t * (3.0 - 2.0 * t),
    };

    let lerp = |a: f64, b: f64| a + (b - a) * t;
    FrameTransform {
        scale: lerp(motion.from.scale, motion.to.scale),
        x: lerp(motion.from.x, motion.to.x),
        y: lerp(motion.from.y, motion.to.y),
    }
}

/// Parses `#RRGGBB` or `#RRGGBBAA`.
pub fn parse_color(hex: &str) -> Option<Color> {
    let digits = hex.strip_prefix('#')?;
    if !digits.is_ascii() || !(digits.len() == 6 || digits.len() == 8) {
        return None;
    }
    let byte = |i: usize| u8::from_str_radix(&digits[i..i + 2], 16).ok();
    let alpha = if digits.len() == 8 { byte(6)? } else { 255 };
    Some(Color::from_rgba8(byte(0)?, byte(2)?, byte(4)?, alpha))
}

/// A new opaque frame filled with `background` (its alpha is ignored: video has none).
pub fn new_frame(width: u32, height: u32, background: Color) -> Option<Pixmap> {
    let mut frame = Pixmap::new(width, height)?;
    let mut opaque = background;
    opaque.set_alpha(1.0);
    frame.fill(opaque);
    Some(frame)
}

/// Draws `source` into `frame` at `placement`, scaled bilinearly. Only the area
/// the visual covers is painted, so a contain-fit visual keeps its letterbox.
pub fn draw_visual(frame: &mut Pixmap, source: PixmapRef, placement: Placement) {
    let scale = placement.scale as f32;
    let (x, y) = (placement.x as f32, placement.y as f32);
    let width = source.width() as f32 * scale;
    let height = source.height() as f32 * scale;

    let Some(area) = Rect::from_xywh(x, y, width, height) else {
        return;
    };
    let paint = Paint {
        shader: Pattern::new(
            source,
            SpreadMode::Pad,
            FilterQuality::Bilinear,
            1.0,
            Transform::from_row(scale, 0.0, 0.0, scale, x, y),
        ),
        ..Paint::default()
    };
    frame.fill_rect(area, &paint, Transform::identity(), None);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    fn view(scale: f64, x: f64, y: f64) -> FrameTransform {
        FrameTransform { scale, x, y }
    }

    // --- place ---------------------------------------------------------------

    #[test]
    fn cover_fills_the_frame_and_centres() {
        // 100x100 into 90x160: scale 1.6 -> 160x160, 35 px cropped each side.
        let p = place((100, 100), (90, 160), Fit::Cover, IDENTITY);
        assert!(approx(p.scale, 1.6), "{p:?}");
        assert!(approx(p.x, -35.0), "{p:?}");
        assert!(approx(p.y, 0.0), "{p:?}");
    }

    #[test]
    fn contain_fits_whole_and_centres() {
        // 100x100 into 90x160: scale 0.9 -> 90x90, 35 px letterbox top and bottom.
        let p = place((100, 100), (90, 160), Fit::Contain, IDENTITY);
        assert!(approx(p.scale, 0.9), "{p:?}");
        assert!(approx(p.x, 0.0), "{p:?}");
        assert!(approx(p.y, 35.0), "{p:?}");
    }

    #[test]
    fn view_scale_multiplies_the_base_scale() {
        let p = place((100, 100), (100, 100), Fit::Cover, view(1.5, 0.0, 0.0));
        assert!(approx(p.scale, 1.5), "{p:?}");
        assert!(approx(p.x, -25.0), "{p:?}");
        assert!(approx(p.y, -25.0), "{p:?}");
    }

    #[test]
    fn pan_of_one_puts_the_visual_edge_on_the_frame_edge() {
        let drawn = 200.0; // 100x100 at scale 2 in a 100x100 frame
        let right = place((100, 100), (100, 100), Fit::Cover, view(2.0, 1.0, 0.0));
        assert!(approx(right.x + drawn, 100.0), "{right:?}"); // right edges meet
        let left = place((100, 100), (100, 100), Fit::Cover, view(2.0, -1.0, 0.0));
        assert!(approx(left.x, 0.0), "{left:?}"); // left edges meet
        let down = place((100, 100), (100, 100), Fit::Cover, view(2.0, 0.0, 1.0));
        assert!(approx(down.y + drawn, 100.0), "{down:?}");
    }

    #[test]
    fn no_pan_range_means_no_pan() {
        // contain at scale 1: the visual fills the frame width exactly, so x cannot move it.
        let p = place((100, 200), (100, 200), Fit::Contain, view(1.0, 1.0, 1.0));
        assert!(approx(p.x, 0.0) && approx(p.y, 0.0), "{p:?}");
    }

    // --- motion_at -----------------------------------------------------------

    fn motion(easing: Option<Easing>) -> Motion {
        Motion {
            from: view(1.0, 0.0, 0.0),
            to: view(2.0, 1.0, -1.0),
            easing,
        }
    }

    #[test]
    fn no_motion_is_the_identity() {
        let t = motion_at(None, 3, 10);
        assert!(approx(t.scale, 1.0) && approx(t.x, 0.0) && approx(t.y, 0.0));
    }

    #[test]
    fn motion_starts_at_from_and_ends_at_to() {
        for easing in [None, Some(Easing::Linear), Some(Easing::EaseInOut)] {
            let m = motion(easing);
            let first = motion_at(Some(&m), 0, 5);
            let last = motion_at(Some(&m), 4, 5);
            assert!(approx(first.scale, 1.0) && approx(first.x, 0.0) && approx(first.y, 0.0));
            assert!(approx(last.scale, 2.0) && approx(last.x, 1.0) && approx(last.y, -1.0));
        }
    }

    #[test]
    fn linear_motion_is_evenly_spaced() {
        let m = motion(Some(Easing::Linear));
        assert!(approx(motion_at(Some(&m), 1, 5).scale, 1.25));
        assert!(approx(motion_at(Some(&m), 2, 5).scale, 1.5));
    }

    #[test]
    fn ease_in_out_starts_slow_and_is_symmetric() {
        let m = motion(Some(Easing::EaseInOut));
        // smoothstep(0.25) = 0.15625, smoothstep(0.5) = 0.5
        assert!(approx(motion_at(Some(&m), 1, 5).scale, 1.15625));
        assert!(approx(motion_at(Some(&m), 2, 5).scale, 1.5));
    }

    #[test]
    fn single_frame_scene_shows_the_from_state() {
        let m = motion(Some(Easing::Linear));
        assert!(approx(motion_at(Some(&m), 0, 1).scale, 1.0));
    }

    // --- parse_color ---------------------------------------------------------

    #[test]
    fn parses_hex_colours() {
        let c = parse_color("#FFD400").expect("six digits");
        assert_eq!(c.to_color_u8().red(), 255);
        assert_eq!(c.to_color_u8().green(), 0xD4);
        assert_eq!(c.to_color_u8().blue(), 0);
        assert_eq!(c.to_color_u8().alpha(), 255);
        assert_eq!(
            parse_color("#00000080").unwrap().to_color_u8().alpha(),
            0x80
        );
    }

    #[test]
    fn rejects_bad_hex_colours() {
        for bad in ["FFD400", "#FFD40", "#GGGGGG", "#FFD4000", "", "#"] {
            assert!(parse_color(bad).is_none(), "{bad:?}");
        }
    }

    // --- drawing (pixel tests) ------------------------------------------------

    const RED: (u8, u8, u8) = (255, 0, 0);
    const BLUE: (u8, u8, u8) = (0, 0, 255);
    const BLACK: (u8, u8, u8) = (0, 0, 0);

    fn px(pixmap: &Pixmap, x: u32, y: u32) -> (u8, u8, u8) {
        let p = pixmap.pixel(x, y).expect("pixel in bounds");
        (p.red(), p.green(), p.blue())
    }

    fn assert_colour(actual: (u8, u8, u8), expected: (u8, u8, u8), at: &str) {
        let close = |a: u8, b: u8| a.abs_diff(b) <= 2;
        assert!(
            close(actual.0, expected.0)
                && close(actual.1, expected.1)
                && close(actual.2, expected.2),
            "{at}: expected {expected:?}, got {actual:?}"
        );
    }

    fn solid(width: u32, height: u32, rgb: (u8, u8, u8)) -> Pixmap {
        let mut pixmap = Pixmap::new(width, height).unwrap();
        pixmap.fill(Color::from_rgba8(rgb.0, rgb.1, rgb.2, 255));
        pixmap
    }

    /// 100x100, left half red, right half blue.
    fn halves() -> Pixmap {
        let mut pixmap = solid(100, 100, RED);
        let mut paint = Paint::default();
        paint.set_color_rgba8(0, 0, 255, 255);
        let right = Rect::from_xywh(50.0, 0.0, 50.0, 100.0).unwrap();
        pixmap.fill_rect(right, &paint, Transform::identity(), None);
        pixmap
    }

    fn black() -> Color {
        Color::from_rgba8(0, 0, 0, 255)
    }

    #[test]
    fn new_frame_is_filled_and_opaque() {
        let frame = new_frame(4, 4, Color::from_rgba8(10, 20, 30, 0)).unwrap();
        let p = frame.pixel(2, 2).unwrap();
        assert_eq!((p.red(), p.green(), p.blue(), p.alpha()), (10, 20, 30, 255));
    }

    #[test]
    fn cover_leaves_no_background_showing() {
        let source = solid(100, 100, RED);
        let mut frame = new_frame(90, 160, black()).unwrap();
        let placement = place((100, 100), (90, 160), Fit::Cover, IDENTITY);
        draw_visual(&mut frame, source.as_ref(), placement);
        for (x, y) in [(0, 0), (89, 0), (0, 159), (89, 159), (45, 80)] {
            assert_colour(px(&frame, x, y), RED, &format!("cover at ({x},{y})"));
        }
    }

    #[test]
    fn contain_leaves_a_letterbox() {
        let source = solid(100, 100, RED);
        let mut frame = new_frame(90, 160, black()).unwrap();
        let placement = place((100, 100), (90, 160), Fit::Contain, IDENTITY);
        draw_visual(&mut frame, source.as_ref(), placement);
        assert_colour(px(&frame, 45, 5), BLACK, "top letterbox");
        assert_colour(px(&frame, 45, 80), RED, "picture");
        assert_colour(px(&frame, 45, 155), BLACK, "bottom letterbox");
    }

    #[test]
    fn pan_moves_the_view_toward_the_positive_edge() {
        // zoom 2x so there is room to pan; frame shows half the picture.
        let source = halves();
        for (x, left, right, label) in [
            (-1.0, RED, RED, "pan to left edge: only the red half"),
            (0.0, RED, BLUE, "centred: red then blue"),
            (1.0, BLUE, BLUE, "pan to right edge: only the blue half"),
        ] {
            let mut frame = new_frame(100, 100, black()).unwrap();
            let placement = place((100, 100), (100, 100), Fit::Cover, view(2.0, x, 0.0));
            draw_visual(&mut frame, source.as_ref(), placement);
            assert_colour(px(&frame, 10, 50), left, &format!("{label}, left side"));
            assert_colour(px(&frame, 90, 50), right, &format!("{label}, right side"));
        }
    }
}
