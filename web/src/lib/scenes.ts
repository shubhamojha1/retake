// Scenes as the pages show them: the plan while the video is made (from the progress map),
// and the finished scenes (from the spec).

import type { StepState } from './steps.ts'
import type { Progress, Spec, StepEntry } from './types.ts'

export interface ScenePlan {
  n: number
  narration: string
  query: string
  footage: StepState
  voice: StepState
}

function stateOf(entry: StepEntry | undefined, stopped: boolean): StepState {
  if (!entry) return 'queued'
  if (entry.status === 'done') return 'done'
  if (entry.status === 'failed') return 'failed'
  // started: still being made, unless the whole job has stopped
  return stopped ? 'queued' : 'running'
}

/** The script scene by scene, with how far each scene's footage and voice-over are. */
export function scenePlan(progress: Progress, stopped: boolean): ScenePlan[] {
  const outline = progress.steps?.script?.outline ?? []

  return outline.map((item, i) => {
    const steps = progress.scenes?.[String(i + 1)]
    return {
      n: i + 1,
      narration: item.narration,
      query: item.query,
      footage: stateOf(steps?.stock, stopped),
      voice: stateOf(steps?.voice, stopped),
    }
  })
}

export interface SceneRow {
  n: number
  narration: string
  query: string
  startMs: number
  endMs: number
  /** "video" or "image": what the scene shows. */
  kind: string | null
}

/** The finished scenes with where each one starts and ends in the video. */
export function sceneRows(spec: Spec): SceneRow[] {
  let start = 0

  return spec.scenes.map((scene, i) => {
    const end = start + scene.duration_ms
    const row: SceneRow = {
      n: i + 1,
      narration: scene.intent?.narration ?? '',
      query: scene.intent?.visual_query ?? '',
      startMs: start,
      endMs: end,
      kind: spec.assets[scene.visual.asset]?.kind ?? null,
    }
    start = end
    return row
  })
}

/** Who to credit for the footage, each once, in the order of the video. */
export function credits(spec: Spec): string[] {
  const names: string[] = []

  for (const scene of spec.scenes) {
    const credit = spec.assets[scene.visual.asset]?.license?.attribution
    if (credit && !names.includes(credit)) names.push(credit)
  }

  return names
}
