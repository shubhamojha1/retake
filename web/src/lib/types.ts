// The shapes the API sends (api/lib/retake_web/controllers/video_json.ex and
// api/lib/retake/videos/progress.ex). Only the parts the pages use.

export type VideoStatus = 'queued' | 'running' | 'succeeded' | 'failed'

/** One step of the pipeline, or one step of one scene. */
export interface StepEntry {
  status: 'started' | 'running' | 'done' | 'failed'
  /** In words, when status is "failed". */
  message?: string
  /** Render: frames done and in all. */
  done?: number
  total?: number
  /** Script: how many scenes, the title, and what each scene says. */
  scenes?: number
  title?: string
  outline?: OutlineItem[]
  /** Visuals: "video" or "image", where it came from ("generated" or "stock"), the search
   *  phrase, who to credit (stock only) and the image prompt (generated only). */
  kind?: string
  source?: string
  query?: string
  credit?: string
  prompt?: string
  /** Voice-over: its length. */
  duration_ms?: number
}

export interface OutlineItem {
  narration: string
  query: string
}

export interface Progress {
  current?: { step: string; scene: number | null }
  /** "brief", "script", "assemble", "render". */
  steps?: Record<string, StepEntry>
  /** By scene number ("1", "2", ...), then "visual" (older jobs: "stock") and "voice". */
  scenes?: Record<string, Record<string, StepEntry>>
}

export interface VideoError {
  step: string
  scene: number | null
  message: string
}

export interface SpecAsset {
  kind: string
  license?: { attribution?: string }
}

export interface SpecScene {
  id: string
  duration_ms: number
  intent?: { narration?: string; visual_query?: string }
  visual: { asset: string }
}

export interface Spec {
  title: string
  output: { width: number; height: number; fps: number }
  assets: Record<string, SpecAsset>
  scenes: SpecScene[]
}

export interface Video {
  id: string
  status: VideoStatus
  brief: { prompt?: string; target_duration_ms?: number; tone?: string }
  profile: string | null
  title: string | null
  progress: Progress
  duration_ms: number | null
  warnings: string[]
  error: VideoError | null
  /** Where the MP4 is, once the job has succeeded. */
  video_url: string | null
  inserted_at: string
  updated_at: string
  /** Only when one video is asked for, not in the list. */
  spec?: Spec | null
}
