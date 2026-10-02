# Retake video spec v0.1

The spec is a JSON document that fully describes one video. Everything in
Retake reads or writes it: the generation pipeline fills it in, the renderer
turns it into an MP4, and (from Phase 3) the edit agent changes it with small
operations.

- Schema: [`video.schema.json`](video.schema.json) (JSON Schema 2020-12)
- Examples: [`examples/minimal.json`](examples/minimal.json) (1 scene),
  [`examples/explainer.json`](examples/explainer.json) (3 scenes, music,
  crossfades, word-highlight captions)

## Rules the design follows

1. **Rendering is deterministic.** Output depends only on the spec, the bytes
   of the referenced assets (checked by `content_hash`), and the renderer
   version. Same inputs, same file.
2. **Intent is separate from result.** Each scene has an `intent` (narration,
   visual search terms, on-screen text) and resolved assets (the clip, the
   voice-over file). Editing intent invalidates the assets derived from it.
   This is what makes "regenerate only what changed" possible in Phase 2.
3. **Assets are referenced by id.** Scenes never embed URLs or file paths. All
   media lives in the top-level `assets` map, with provenance and licence.
4. **Every asset records where it came from.** Provider, model, the normalised
   request, its hash, the time, and the cost. `request_hash` is the cache key.
5. **No secrets in the spec.** Provenance stores requests, never API keys or
   auth headers.

## Timing model

- All times are integer milliseconds.
- Scenes play in array order. Scene *n* starts where scene *n-1* ends, minus
  the overlap of scene *n*'s `transition_in` (crossfade or fade through black).
- Times inside a scene (`offset_ms`, overlays) are relative to the scene start.
  Word timings are relative to the start of the voice-over asset.
- The renderer converts milliseconds to frames at `output.fps`, rounding to
  the nearest frame. Frame-exact rational time is a v1 concern.

```
scene start ──┬── offset_ms ──┬── voice-over (words timed from here) ──┐
              │               │                                        │
              └────────────────────── duration_ms ─────────────────────┘
```

## Checks beyond the JSON Schema

JSON Schema validates shape. The `Spec.validate/1` function must also check:

| Rule | Why |
|---|---|
| Every referenced asset id exists in `assets` | No dangling references |
| `visual.asset` is an image or video; `voiceover.asset` and `music.asset` are audio | Right media type in the right slot |
| `voiceover.offset_ms + voice-over duration ≤ scene.duration_ms` | Speech never gets cut off |
| `transition_in.duration_ms < min(previous scene, this scene duration)` | Overlap can't swallow a scene |
| First scene's `transition_in` is null or a cut | Nothing to transition from |
| Words are in order, non-overlapping, and `end_ms ≤` voice-over duration | Captions stay in sync |
| Overlay `start_ms < end_ms ≤ scene.duration_ms` | Overlays stay inside their scene |
| Video asset: `trim_start_ms + scene.duration_ms ≤ media.duration_ms`, or the renderer loops/freezes (decide and document) | Clip must be long enough |
| Total duration within ±25% of `brief.target_duration_ms` | Pipeline sanity check, warning only |
| `content_hash` matches the bytes at `uri` (render time) | Determinism |

## How the Phase 1 pipeline fills the spec

| Step | Writes |
|---|---|
| 1. LLM: brief → title + scenes | `title`, `scenes[].intent` |
| 2. Stock search per scene | `assets` (image/video), `scenes[].visual` |
| 3. TTS per scene | `assets` (audio), `scenes[].voiceover.asset` |
| 4. STT on each voice-over | `scenes[].voiceover.words` |
| 5. Timing pass | `scenes[].duration_ms` (voice-over + padding), transitions |
| 6. Music pick by tone | `assets` (music), `music` |
| 7. Validate → render | the MP4 |

Steps 2–4 run per scene in parallel. Each step is a cache lookup first.

## Deliberately not in v0

- Aspect ratios other than 9:16 (the schema pins 1080×1920)
- Multiple visual layers per scene, picture-in-picture, keyframed animation
- Per-word caption styling, emoji, custom caption animations
- Generated images or video (stock only), avatars, lip sync
- Sound effects, multiple music tracks
- Brand kits and templates
- Rational/frame-exact timing

Each is a later minor version. Any change to the format bumps `spec_version`,
and the loader keeps a migration for every older version.

## Open questions to settle while building the renderer

- Video clip shorter than its scene: loop, freeze the last frame, or reject?
- Font handling: bundle a small set of fonts (e.g. Inter) and treat font files
  as assets with hashes, so text renders identically everywhere?
- Where the LUFS loudness pass runs: in the Rust renderer or via FFmpeg's
  `loudnorm` filter.
