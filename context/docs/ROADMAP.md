# Retake roadmap

Each phase ends with a product you can use and test, built on the previous one.
Only Phase 1 is active. Do not build ahead.

| Phase | You can… | Key pieces |
|---|---|---|
| **1. MVP** *(active)* | Type a topic, watch progress, download a 30–60 s vertical video with voice-over, captions, stock visuals and music | Spec v0.1, Rust renderer (spec → MP4), Elixir pipeline (LLM → stock → TTS → STT → render), provider layer with profiles, asset store + request cache, minimal web UI |
| 2. Scene editor | Edit a scene's script, swap its clip, regenerate one scene, reorder/trim; only changed parts regenerate and re-render; undo to any version | Dependency tracking, chunked render, versions, cost estimate |
| 3. Chat editing ("Agent One" level) | Refine by chatting ("make scene 2 punchier") | Edit agent emitting validated spec operations, eval suite, full provider settings + budgets |
| 4. Your voice and brand | Record your own voice-over, clone your voice, apply a brand kit, live browser preview | Timbre recorder + DSP, forced alignment, renderer → WASM preview |
| 5. Generated video | AI clips instead of stock, consistent characters, camera/shot control | Video/image model adapters, reference library, Oban jobs |
| 6. Project memory ("Agent Two" level) | Long projects; agent remembers characters/locations/style; one edit across all shots; per-shot model choice; branches | Project bible + retrieval, bulk ops, model router, branching |
| 7. Multiplayer | Several people edit live, comment, shared voice-over | Real-time spec sync, presence, Timbre session mixer |
| 8. Your footage | Upload, edit by transcript, long → shorts, auto-reframe | Ingest pipeline, transcript editing, highlight detection, tracking |
| 9. Avatars and dubbing | Avatar presenter, translate + re-voice + lip-sync | Avatar/lip-sync adapters, language variants |
| 10. Platform | Fully local mode, API/CLI/templates, plugins, AI quality check | Local model profile, batch templates, WASM plugins, C2PA |

## Phase 1: done when

- 10 different prompts each produce a watchable video with no manual fixes.
- Rendering the same spec twice gives byte-identical output.
- Every provider call's cost and usage is recorded in asset provenance.
- The `test` profile runs the whole suite with no network access.
