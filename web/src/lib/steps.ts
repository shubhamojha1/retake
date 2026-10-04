// The steps of a video job as the Generating page shows them, worked out from the job's
// `progress` map (api/lib/retake/videos/progress.ex), its status and its error.

import type { Progress, StepEntry, VideoError, VideoStatus } from './types.ts'

export type StepKey = 'script' | 'footage' | 'voice' | 'render'
export type StepState = 'queued' | 'running' | 'done' | 'failed'

export interface StepRow {
  key: StepKey
  name: string
  state: StepState
  detail: string
  /** 0 to 100 while running and the share done is known, else null. */
  pct: number | null
}

interface Job {
  status: VideoStatus
  progress: Progress
  error: VideoError | null
}

type Part = Pick<StepRow, 'state' | 'detail' | 'pct'>

const ORDER: StepKey[] = ['script', 'footage', 'voice', 'render']

const NAMES: Record<StepKey, string> = {
  script: 'Script',
  footage: 'Footage',
  voice: 'Voice-over',
  render: 'Render',
}

// Which row a failed pipeline step belongs to ("brief", "setup" and the like belong to none).
const ROW_OF_STEP: Record<string, StepKey | undefined> = {
  script: 'script',
  stock: 'footage',
  voice: 'voice',
  assemble: 'render',
  render: 'render',
}

const STEP_WORDS: Record<string, string> = {
  brief: 'checking the request',
  setup: 'setting up',
  script: 'the script',
  stock: 'finding footage',
  voice: 'the voice-over',
  assemble: 'putting the scenes together',
  render: 'the render',
  pipeline: 'the pipeline',
  interrupted: 'a restart of the app',
}

const firstLine = (text: string | undefined): string => (text ?? '').split('\n')[0]

const queued = (detail: string): Part => ({ state: 'queued', detail, pct: null })
const running = (detail: string, pct: number | null = null): Part => ({ state: 'running', detail, pct })
const done = (detail: string): Part => ({ state: 'done', detail, pct: null })
const failed = (detail: string): Part => ({ state: 'failed', detail, pct: null })

const share = (part: number, whole: number): number =>
  whole > 0 ? Math.min(100, Math.round((part / whole) * 100)) : 0

function scriptPart(progress: Progress): Part {
  const entry = progress.steps?.script
  if (!entry) return queued('Waiting')
  if (entry.status === 'failed') return failed(firstLine(entry.message))
  if (entry.status === 'done') {
    const title = entry.title ? ` for “${entry.title}”` : ''
    return done(`${entry.scenes ?? 0} scenes${title}`)
  }
  return running('Writing the script')
}

// Footage and voice-over: one entry per scene, so count the scenes that are done.
function perScenePart(progress: Progress, step: 'stock' | 'voice', what: string): Part {
  const entries: [string, StepEntry][] = []
  for (const [scene, steps] of Object.entries(progress.scenes ?? {})) {
    const entry = steps[step]
    if (entry) entries.push([scene, entry])
  }

  const broken = entries.find(([, entry]) => entry.status === 'failed')
  if (broken) return failed(`Scene ${broken[0]}: ${firstLine(broken[1].message)}`)

  const script = progress.steps?.script
  if (script?.status !== 'done') return queued('Waiting for the script')

  const total = script.scenes ?? entries.length
  const finished = entries.filter(([, entry]) => entry.status === 'done').length
  const detail = `${finished} of ${total} ${what}`
  return total > 0 && finished >= total ? done(detail) : running(detail, share(finished, total))
}

// Putting the scenes together and rendering are one row: from the user's side it is one wait.
function renderPart(progress: Progress): Part {
  const assemble = progress.steps?.assemble
  const render = progress.steps?.render

  const broken = [assemble, render].find((entry) => entry?.status === 'failed')
  if (broken) return failed(firstLine(broken.message))

  if (render?.status === 'done') return done('Rendered')
  if (render) {
    const pct = share(render.done ?? 0, render.total ?? 0)
    return running(`${pct}%`, pct)
  }
  if (assemble) return running('Putting the scenes together', 0)
  return queued('Waiting for the footage and voice-overs')
}

export function buildSteps({ status, progress, error }: Job): StepRow[] {
  const parts: Record<StepKey, Part> = {
    script: scriptPart(progress),
    footage: perScenePart(progress, 'stock', 'clips and photos found'),
    voice: perScenePart(progress, 'voice', 'narrated and timed'),
    render: renderPart(progress),
  }
  const rows: StepRow[] = ORDER.map((key) => ({ key, name: NAMES[key], ...parts[key] }))

  if (status === 'succeeded') {
    return rows.map((row): StepRow => (row.state === 'done' ? row : { ...row, state: 'done', pct: null }))
  }

  if (status === 'failed') {
    const broken = error ? ROW_OF_STEP[error.step] : undefined
    return rows.map((row): StepRow => {
      if (row.key === broken && row.state !== 'failed') {
        return { ...row, state: 'failed', detail: firstLine(error?.message), pct: null }
      }
      // The pipeline stops at the first failure: what was still running is stopped.
      return row.state === 'running' ? { ...row, state: 'queued', detail: 'Stopped', pct: null } : row
    })
  }

  // Running, but between two events (nothing in progress yet): the next row is about to start.
  if (status === 'running' && !rows.some((row) => row.state === 'running')) {
    const next = rows.findIndex((row) => row.state === 'queued')
    if (next >= 0) {
      const detail = rows[next].key === 'script' ? 'Writing the script' : 'Starting'
      return rows.map((row, i): StepRow => (i === next ? { ...row, state: 'running', detail } : row))
    }
  }

  return rows
}

/** "Stopped at the voice-over (scene 3)" for a failed job. */
export function stoppedAt(error: VideoError): string {
  const where = STEP_WORDS[error.step] ?? error.step
  return error.scene ? `Stopped at ${where} (scene ${error.scene})` : `Stopped at ${where}`
}
