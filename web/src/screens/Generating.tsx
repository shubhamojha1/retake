import { useState } from 'react'

import { AlertIcon, CheckIcon } from '../components/icons.tsx'
import { ApiError, createVideo } from '../lib/api.ts'
import { retryBrief } from '../lib/brief.ts'
import { shorten } from '../lib/format.ts'
import { href } from '../lib/route.ts'
import { scenePlan } from '../lib/scenes.ts'
import { buildSteps, stoppedAt } from '../lib/steps.ts'
import type { StepState } from '../lib/steps.ts'
import { toneFor } from '../lib/tone.ts'
import type { Video } from '../lib/types.ts'

function StepIcon({ state }: { state: StepState }) {
  if (state === 'done') {
    return (
      <span role="img" aria-label="Done" className="flex size-6 items-center justify-center rounded-full bg-ok-bg text-ok">
        <CheckIcon size={14} />
      </span>
    )
  }

  if (state === 'failed') {
    return (
      <span role="img" aria-label="Failed" className="flex size-6 items-center justify-center rounded-full bg-warn-bg text-warn">
        <AlertIcon size={14} />
      </span>
    )
  }

  if (state === 'running') {
    return (
      <svg role="img" aria-label="Running" className="size-6 motion-safe:animate-spin" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="9" stroke="#2A2A33" strokeWidth="2.5" />
        <path d="M12 3a9 9 0 0 1 9 9" stroke="#FF6A3D" strokeWidth="2.5" strokeLinecap="round" />
      </svg>
    )
  }

  return <span role="img" aria-label="Queued" className="block size-6 rounded-full border-2 border-[#2a2a33]" />
}

const VOICE: Record<StepState, { text: string; color: string }> = {
  done: { text: 'voice ready', color: 'text-ok' },
  running: { text: 'voicing…', color: 'text-accent' },
  queued: { text: 'waiting', color: 'text-label' },
  failed: { text: 'failed', color: 'text-warn' },
}

const HEADING = { queued: 'Starting', running: 'Generating', failed: 'Failed', succeeded: 'Done' }

/** A video being made: the steps, live, and the script scene by scene. Also what a failed one looks like. */
export default function Generating({ video }: { video: Video }) {
  const [retrying, setRetrying] = useState(false)
  const [retryProblem, setRetryProblem] = useState<string | null>(null)

  const rows = buildSteps(video)
  const plan = scenePlan(video.progress, video.status === 'failed')
  const prompt = video.brief.prompt ?? ''
  const title = video.title ?? shorten(prompt, 60)

  async function retry() {
    const brief = retryBrief(video.brief)
    if (!brief) return

    setRetrying(true)
    setRetryProblem(null)
    try {
      const again = await createVideo(brief)
      window.location.hash = href.video(again.id)
    } catch (error) {
      setRetryProblem(error instanceof ApiError ? error.problems.join(' ') : 'Something went wrong.')
      setRetrying(false)
    }
  }

  return (
    <div className="mx-auto flex w-full max-w-[1120px] flex-wrap items-start gap-10 px-6 py-12 md:px-10">
      <section aria-labelledby="title" className="min-w-0 flex-[1_1_480px]">
        <div className={`text-[13px] ${video.status === 'failed' ? 'text-warn' : 'text-label'}`}>{HEADING[video.status]}</div>
        <h1 id="title" className="mt-1.5 text-[32px] leading-[1.15] font-semibold tracking-[-0.025em]">
          {title}
        </h1>
        <p className="mt-2.5 text-sm leading-normal text-muted">{prompt}</p>

        <ol className="mt-8 overflow-hidden rounded-2xl border border-hair bg-deep">
          {rows.map((row) => (
            <li key={row.key} className="flex gap-4 border-t border-hair px-5 py-[18px] first:border-t-0">
              <div className="mt-px size-6 flex-none">
                <StepIcon state={row.state} />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-3">
                  <span
                    className={`text-[15px] font-medium ${
                      row.state === 'queued' ? 'text-label' : row.state === 'failed' ? 'text-warn' : ''
                    }`}
                  >
                    {row.name}
                  </span>
                  {row.state === 'running' && row.pct !== null && (
                    <span className="font-mono text-xs text-label">{row.pct}%</span>
                  )}
                </div>
                <div className="mt-[3px] text-[13px] break-words text-muted">{row.detail}</div>
                {row.state === 'running' && row.pct !== null && (
                  <div
                    role="progressbar"
                    aria-label={`${row.name} progress`}
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-valuenow={row.pct}
                    className="mt-3 h-1 overflow-hidden rounded-sm bg-hair"
                  >
                    <div className="h-full rounded-sm bg-accent transition-[width]" style={{ width: `${row.pct}%` }} />
                  </div>
                )}
              </div>
            </li>
          ))}
        </ol>

        {video.status === 'failed' && video.error && (
          <div role="alert" className="mt-5 rounded-xl border border-warn/40 bg-warn-bg px-4 py-3.5">
            <div className="text-sm font-medium text-warn">{stoppedAt(video.error)}</div>
            <pre className="mt-2 font-mono text-xs leading-relaxed whitespace-pre-wrap text-warn/90">{video.error.message}</pre>
            <p className="mt-2 text-xs leading-normal text-muted">
              The steps that worked are cached, so trying again is quick. If it fails the same way, change the prompt.
            </p>
            {retryProblem && <p className="mt-2 text-xs text-warn">{retryProblem}</p>}
            <button
              type="button"
              onClick={retry}
              disabled={retrying}
              className="mt-3 inline-flex h-10 items-center rounded-[10px] bg-accent px-4 text-sm font-semibold text-on-accent hover:brightness-110 disabled:opacity-60"
            >
              {retrying ? 'Starting…' : 'Try again'}
            </button>
          </div>
        )}

        <div className="mt-5 flex flex-wrap items-center gap-3">
          <a href={href.create} className="inline-flex h-10 items-center rounded-[10px] border border-line px-4 text-sm hover:bg-raised">
            New video
          </a>
        </div>
        <p className="mt-5 text-xs leading-normal text-label">
          Every provider call is cached by its request. Running the same prompt again reuses the script, clips and
          voice-over at no cost.
        </p>
      </section>

      <aside aria-labelledby="script" className="max-w-[440px] min-w-0 flex-[1_1_340px]">
        <h2 id="script" className="mb-3.5 text-[15px] font-semibold">
          Script
        </h2>
        {plan.length === 0 ? (
          <p className="text-[13px] text-muted">The script appears here once it is written.</p>
        ) : (
          <div className="flex flex-col gap-2.5">
            {plan.map((scene) => (
              <div
                key={scene.n}
                className={`flex gap-3.5 rounded-[14px] border border-hair bg-surface p-3.5 ${
                  scene.footage === 'queued' && scene.voice === 'queued' ? 'opacity-60' : ''
                }`}
              >
                <div className="h-[78px] w-11 flex-none rounded-lg" style={{ background: toneFor(`${video.id}-${scene.n}`) }} />
                <div className="min-w-0 flex-1">
                  <div className="text-xs text-label">Scene {scene.n}</div>
                  <div className="mt-1.5 text-[13px] leading-snug text-[#d4d4dc]">{scene.narration}</div>
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    <span
                      className={`inline-flex h-5 items-center rounded-md bg-raised px-2 text-[11px] ${
                        scene.footage === 'failed' ? 'text-warn' : 'text-muted'
                      }`}
                    >
                      {scene.query}
                    </span>
                    <span className={`inline-flex h-5 items-center rounded-md bg-raised px-2 text-[11px] ${VOICE[scene.voice].color}`}>
                      {VOICE[scene.voice].text}
                    </span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </aside>
    </div>
  )
}
