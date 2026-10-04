import { useState } from 'react'
import type { FormEvent } from 'react'

import { ArrowRightIcon, ChevronDownIcon } from '../components/icons.tsx'
import VideoCard from '../components/VideoCard.tsx'
import { useVideos } from '../hooks/useVideo.ts'
import { ApiError, createVideo } from '../lib/api.ts'
import { buildBrief, DEFAULT_LENGTH_MS, IDEAS, LENGTHS, promptProblem, TONES } from '../lib/brief.ts'
import { href } from '../lib/route.ts'

interface Option {
  label: string
  value: string
}

/** An option that looks like a chip and is a native select underneath: keyboard and screen reader for free. */
function Chip({ label, value, options, onChange }: { label: string; value: string; options: Option[]; onChange: (value: string) => void }) {
  return (
    <label className="relative inline-flex h-9 items-center gap-2 rounded-[10px] border border-line px-3 text-[13px] focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-accent hover:bg-raised">
      <span className="text-label">{label}</span>
      <select
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="cursor-pointer appearance-none bg-transparent pr-5 font-medium outline-none"
      >
        {options.map((option) => (
          <option key={option.value} value={option.value} className="bg-surface text-text">
            {option.label}
          </option>
        ))}
      </select>
      <span className="pointer-events-none absolute right-3 text-label">
        <ChevronDownIcon size={14} />
      </span>
    </label>
  )
}

export default function Create() {
  const [prompt, setPrompt] = useState('')
  const [lengthMs, setLengthMs] = useState(DEFAULT_LENGTH_MS)
  const [tone, setTone] = useState('')
  const [busy, setBusy] = useState(false)
  const [problems, setProblems] = useState<string[]>([])
  const { videos } = useVideos(4)

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const problem = promptProblem(prompt)
    if (problem) {
      setProblems([problem])
      return
    }

    setBusy(true)
    setProblems([])
    try {
      const video = await createVideo(buildBrief({ prompt, lengthMs, tone }))
      window.location.hash = href.video(video.id)
    } catch (error) {
      setProblems(error instanceof ApiError ? error.problems : ['Something went wrong.'])
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-screen flex-col">
      <header className="flex h-16 flex-none items-center px-8">
        <span className="text-[15px] font-semibold tracking-tight">Retake</span>
      </header>

      <div className="mx-auto w-full max-w-[880px] flex-1 px-6 pt-10 pb-16 md:px-8 md:pt-14">
        <h1 className="text-center text-4xl leading-[1.1] font-semibold tracking-[-0.03em] md:text-[44px]">What should we make?</h1>
        <p className="mt-3.5 text-center text-base leading-normal text-muted">
          Describe a video. Retake writes it, finds the footage, voices it and renders it.
        </p>

        <form
          onSubmit={submit}
          className="mt-9 rounded-[20px] border border-line bg-surface px-5 pt-5 pb-4 focus-within:border-accent"
        >
          <label htmlFor="prompt" className="sr-only">
            Video prompt
          </label>
          <textarea
            id="prompt"
            rows={3}
            value={prompt}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder="A 45-second explainer on why we dream. Calm tone, night-sky footage, simple language."
            className="w-full resize-none border-0 bg-transparent text-lg leading-[1.55] outline-0"
          />
          <div className="mt-3.5 flex flex-wrap items-center gap-2">
            <span className="inline-flex h-9 items-center gap-2 rounded-[10px] border border-line px-3 text-[13px]">
              <span className="text-label">Format</span>
              <span className="font-medium">9:16</span>
            </span>
            <Chip
              label="Length"
              value={String(lengthMs)}
              options={LENGTHS.map(({ label, ms }) => ({ label, value: String(ms) }))}
              onChange={(value) => setLengthMs(Number(value))}
            />
            <Chip label="Tone" value={tone} options={TONES} onChange={setTone} />
            <button
              type="submit"
              disabled={busy}
              className="ml-auto inline-flex h-11 items-center gap-2 rounded-xl bg-accent px-5 text-[15px] font-semibold text-on-accent hover:brightness-110 disabled:opacity-60"
            >
              {busy ? 'Starting…' : 'Generate'}
              <ArrowRightIcon size={18} />
            </button>
          </div>
        </form>

        {problems.length > 0 && (
          <div role="alert" className="mt-3 rounded-xl border border-warn/40 bg-warn-bg px-4 py-3 text-[13px] text-warn">
            {problems.map((problem) => (
              <p key={problem}>{problem}</p>
            ))}
          </div>
        )}

        <div className="mt-4 flex flex-wrap justify-center gap-2">
          {IDEAS.map((idea) => (
            <button
              key={idea.label}
              type="button"
              onClick={() => setPrompt(idea.prompt)}
              className="h-[34px] rounded-full border border-hair px-3.5 text-[13px] text-muted hover:bg-raised"
            >
              {idea.label}
            </button>
          ))}
        </div>

        {videos && videos.length > 0 && (
          <section aria-labelledby="recent" className="mt-16">
            <div className="flex items-baseline justify-between">
              <h2 id="recent" className="text-[15px] font-semibold">
                Recent
              </h2>
              <a href={href.projects} className="text-[13px] text-label hover:text-text">
                View all
              </a>
            </div>
            <div className="mt-4 flex flex-wrap gap-5">
              {videos.map((video) => (
                <VideoCard key={video.id} video={video} />
              ))}
            </div>
          </section>
        )}
      </div>
    </div>
  )
}
