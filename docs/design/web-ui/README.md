# Retake web UI: design handoff

Mockups for the `web/` app (React + Vite + TypeScript + Tailwind v4). Reference
style: invideo.io (prompt-first home, scene storyboard, preview + timeline +
inspector editor). Design goals: sleek, modern, minimal weight, no UI library.

Live canvas (private, owner only): https://claude.ai/artifact/VZPNbA9QVgZwKNm14Px7dy

## What these files are

Each `*.dc.html` is one screen, written in a design-tool markup format. They are
**visual specs, not code to copy**. Open the markup to read exact sizes, colors,
spacing, copy and states, then rebuild each screen as React components.

- Inline `style="..."` holds the real values (px, hex, radii, gaps).
- `{{ hole }}` / `<sc-for>` / `<sc-if>` mark data-driven parts. The data arrays
  in each file's `<script type="text/x-dc">` block are **sample content**, not
  real data. Replace them with API data.
- `<helmet><style>` holds hover and focus rules (`.hv:hover`, `:focus-visible`,
  spin animation). Port these to Tailwind variants.
- `canvas.json` is only the canvas layout (artboard positions). Ignore it when
  building.
- Do not try to run or render these files in the app.

## Screens, phase and build order

| File | Screen | Phase | Notes |
|---|---|---|---|
| `Main.dc.html` | Create: prompt box, option chips, idea chips, recent projects | 1 | Core of F14. |
| `Progress.dc.html` | Live pipeline steps, spend vs cap, script building up | 1 | F14: driven by the Channel progress events from F13. |
| `Result.dc.html` | 9:16 player, read-only scene list, details, Download MP4 | 1 | F14: player and download link. "Edit scenes" is a disabled Phase 2 tag. |
| `Providers.dc.html` | Read-only profile / provider / key-present status, budgets, cache paths | 1, optional | Needs an API endpoint that does not exist yet (see below). |
| `Editor.dc.html` | Scene editor: scenes, preview, timeline, inspector, stale/regenerate | **2** | **Do not build.** Hard rule 10. Kept as the target the Result screen grows into. It already shows the interaction model (edit narration marks a scene stale, "Regenerate changed (n)"). |
| `Foundations.dc.html` | Colors, type scale, radii, components, Tailwind `@theme` snippet | n/a | Build this first. |

Suggested order: Foundations tokens into `web/src/index.css` → app shell and
left rail → Create → Progress → Result → Providers (only if the endpoint is
added).

## Design tokens

Dark only. One accent. Fonts: Geist and Geist Mono (Google Fonts link is in each
file's `<helmet>`; self-host if the app must work offline).

```css
@theme {
  --color-bg: #0A0A0C;      --color-surface: #121216;  --color-raised: #1A1A20;
  --color-line: #26262E;    --color-text: #EDEDF0;     --color-muted: #9A9AA6;
  --color-label: #8A8A96;   --color-accent: #FF6A3D;   --color-ok: #5BD68A;
  --color-warn: #F5B544;
  --font-sans: "Geist", system-ui, sans-serif;
  --font-mono: "Geist Mono", monospace;
}
```

Also used: hairline `#1F1F26`/`#1C1C22`, deep surface `#0E0E12`, ok badge bg
`#16301F`, warn badge bg `#33280F`, accent text on accent buttons `#1A0B06`.
Radii: 6 / 10 (inputs, buttons) / 12–14 (cards) / 20 (prompt) / pill.
Heights: buttons 36–44 px, chips 34–36 px. Focus ring: 2 px accent, 2 px offset.
Mono font for all times and money.

## Layout notes

- Left rail 68 px (Create, Projects, Providers), logo is a small accent dot. On
  narrow screens it should become a bottom bar.
- Content max widths: Create 880, Progress/Result/Providers 1120.
- Screens are fluid pages: `flex-wrap` rows that stack at phone width. Video is
  always 9:16 (preview 360×640 on Result).
- Icons are inline stroke SVG (24 viewBox, 1.75 stroke). Keep them inline, no
  icon package.
- Respect `prefers-reduced-motion` for the progress spinner and pulse.
- Use real `<button>`, `<a>`, `<label>`; icon-only buttons need `aria-label`.

## Wiring to the existing project

Current state: `web/src/App.tsx` is a placeholder; API only has `GET /api/health`.
Relevant work queue items in `features.json`: **F13** (adds `POST /api/videos`,
`GET /api/videos/:id`, media serving, Channel progress events) and **F14**
(web MVP: prompt box, live progress over a Channel, player, download link).
Vite proxies `/api` and `/socket` to :4010.

Mapping:

- **Create** → `POST /api/videos` with the prompt and options, then navigate to
  Progress. Chips map to spec `brief`/output options (format, target duration,
  voice, captions, music). Chips in the mockup are static; start with only the
  options the F13 request accepts.
- **Progress** → subscribe to the video's Channel. Steps shown: script,
  footage, voice-over, word timing, render. Each step's provider, time and cost
  come from provenance. Spend bar = running cost vs
  `budget.max_cost_per_video_usd`. Failures must show which step and scene.
- **Result** → `GET /api/videos/:id` plus the served MP4 for the player and the
  download link. Scene list comes from the spec (`intent` narration, visual
  search terms, resolved asset provenance).
- **Recent projects** (Create) and **Providers** → no endpoint yet. Add
  `GET /api/videos` and a read-only providers status endpoint (profile, provider
  per capability, fallbacks, whether the env var for each key is set, budgets,
  cache/storage paths) only if you decide they belong in Phase 1. If not, cut
  the recents grid and the Providers screen for now. Never return key values.

## Constraints from AGENTS.md that affect the UI

- Work one `features.json` feature at a time; mark passing only after its
  verification command succeeds, log in `PROGRESS.md`. These mockups map to F14.
- Phase 1 only (rule 10): no editing, regeneration, chat, versions or brand kit.
- API keys come only from environment variables. The UI never accepts, shows or
  stores a key (rule 7). The Providers screen is deliberately read-only.
- Tests never touch the network (rule 6). Web tests use `node --test` in
  `web/test/`; keep logic in `web/src/lib/` as pure functions so it can be
  tested like `format.ts`.
- Record non-obvious design choices in `DECISIONS.md` with their cost (rule 11),
  e.g. Geist fonts and no component library.
- Do not commit unless the user asks (rule 12). Give exact commands and expected
  output instead of claiming a pass.

## Sample content to replace

Project "Why we dream", its five scenes, durations (0:44 total), clip names,
"$0.00" costs, "Failed" recent project and the missing `PEXELS_API_KEY` state
are illustrative. The failed and key-missing states are intentional examples of
error and warning styling.
