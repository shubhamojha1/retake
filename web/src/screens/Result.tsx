import Badge from '../components/Badge.tsx'
import { DownloadIcon } from '../components/icons.tsx'
import { formatDuration, formatRange, timeAgo } from '../lib/format.ts'
import { href } from '../lib/route.ts'
import { credits, sceneRows } from '../lib/scenes.ts'
import { toneFor } from '../lib/tone.ts'
import type { Video } from '../lib/types.ts'

/** A finished video: the player, the scenes, the details, the credits, the download. */
export default function Result({ video }: { video: Video }) {
  const spec = video.spec
  const scenes = spec ? sceneRows(spec) : []
  const credit = spec ? credits(spec) : []
  const url = video.video_url

  const facts = [
    { label: 'Length', value: formatDuration(video.duration_ms ?? 0) },
    { label: 'Format', value: spec ? `${spec.output.width} × ${spec.output.height} · ${spec.output.fps} fps` : '—' },
    { label: 'Scenes', value: String(scenes.length) },
    { label: 'Made', value: timeAgo(video.inserted_at) },
  ]

  return (
    <div className="flex min-h-screen flex-col">
      <header className="flex min-h-16 flex-none flex-wrap items-center justify-between gap-3 border-b border-rail px-6 py-3 md:px-8">
        <div className="flex min-w-0 items-center gap-2.5 text-sm">
          <a href={href.projects} className="text-label hover:text-text">
            Projects
          </a>
          <span className="text-[#3a3a46]">/</span>
          <h1 className="truncate text-sm font-semibold">{video.title ?? 'Untitled'}</h1>
          <Badge status={video.status} />
        </div>
        <div className="flex items-center gap-2.5">
          <span
            aria-disabled="true"
            className="inline-flex h-10 items-center gap-2 rounded-[10px] border border-line px-3.5 text-sm text-label"
          >
            Edit scenes
            <span className="inline-flex h-[18px] items-center rounded-[5px] bg-hair px-1.5 text-[10px] font-medium tracking-wider text-muted">
              PHASE 2
            </span>
          </span>
          {url && (
            <a
              href={`${url}?download=1`}
              className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-accent px-4 text-sm font-semibold text-on-accent hover:brightness-110"
            >
              <DownloadIcon size={18} />
              Download MP4
            </a>
          )}
        </div>
      </header>

      <div className="flex-1 px-6 py-9 md:px-8">
        <div className="mx-auto flex max-w-[1120px] flex-wrap items-start gap-12">
          <section aria-label="Video preview" className="mx-auto flex-none">
            {url && (
              <video
                src={url}
                controls
                playsInline
                preload="metadata"
                className="aspect-[9/16] w-[360px] max-w-full rounded-3xl border border-line bg-black"
              />
            )}
          </section>

          <div className="flex min-w-0 flex-[1_1_440px] flex-col gap-8">
            {scenes.length > 0 && (
              <section aria-labelledby="scenes">
                <h2 id="scenes" className="mb-3.5 text-[15px] font-semibold">
                  Scenes
                </h2>
                <div className="rounded-2xl border border-hair bg-deep">
                  {scenes.map((scene) => (
                    <div key={scene.n} className="flex gap-4 border-t border-hair px-4 py-3.5 first:border-t-0">
                      <div className="h-[72px] w-10 flex-none rounded-lg" style={{ background: toneFor(`${video.id}-${scene.n}`) }} />
                      <div className="min-w-0 flex-1">
                        <div className="flex justify-between gap-3 text-xs text-label">
                          <span>
                            Scene {scene.n}
                            {scene.query && ` · ${scene.query}`}
                          </span>
                          <span className="font-mono">{formatRange(scene.startMs, scene.endMs)}</span>
                        </div>
                        <div className="mt-[5px] text-sm leading-snug text-[#d4d4dc]">{scene.narration}</div>
                      </div>
                    </div>
                  ))}
                </div>
              </section>
            )}

            <section aria-labelledby="details" className="flex flex-wrap gap-4">
              <h2 id="details" className="basis-full text-[15px] font-semibold">
                Details
              </h2>
              {facts.map((fact) => (
                <div key={fact.label} className="flex-[1_1_180px] rounded-[14px] border border-hair bg-surface px-4 py-3.5">
                  <div className="text-xs text-label">{fact.label}</div>
                  <div className="mt-1 text-[15px] font-medium">{fact.value}</div>
                </div>
              ))}
            </section>

            {video.warnings.length > 0 && (
              <section aria-labelledby="notes" className="rounded-[14px] border border-warn/40 bg-warn-bg px-4 py-3.5">
                <h2 id="notes" className="text-sm font-medium text-warn">
                  Heads-up
                </h2>
                <ul className="mt-2 list-disc space-y-1 pl-4 text-[13px] leading-normal text-warn/90">
                  {video.warnings.map((warning) => (
                    <li key={warning}>{warning}</li>
                  ))}
                </ul>
              </section>
            )}

            <section aria-labelledby="credits" className="rounded-[14px] border border-hair bg-surface px-4 py-3.5">
              <h2 id="credits" className="text-sm font-medium">
                Credits
              </h2>
              {credit.length > 0 ? (
                <ul className="mt-2 list-disc space-y-1 pl-4 text-[13px] leading-normal text-muted">
                  {credit.map((name) => (
                    <li key={name}>{name}</li>
                  ))}
                </ul>
              ) : (
                <p className="mt-2 text-[13px] text-muted">Nothing to credit.</p>
              )}
              <p className="mt-3 text-xs leading-normal text-label">
                Every clip and the voice-over keep their provider and request in the video’s provenance record.
              </p>
            </section>
          </div>
        </div>
      </div>
    </div>
  )
}
