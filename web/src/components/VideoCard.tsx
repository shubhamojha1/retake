import { formatDuration, shorten, timeAgo } from '../lib/format.ts'
import { href } from '../lib/route.ts'
import { stoppedAt } from '../lib/steps.ts'
import { toneFor } from '../lib/tone.ts'
import type { Video } from '../lib/types.ts'
import Badge from './Badge.tsx'

/** A video in a list: a coloured 9:16 tile (there is no thumbnail yet), its title and when. */
export default function VideoCard({ video }: { video: Video }) {
  const title = video.title ?? shorten(video.brief.prompt ?? 'Untitled', 48)
  const scenes = video.progress.steps?.script?.scenes
  const meta =
    video.status === 'failed' && video.error
      ? stoppedAt(video.error)
      : [scenes ? `${scenes} scenes` : null, timeAgo(video.inserted_at)].filter(Boolean).join(' · ')

  return (
    <a href={href.video(video.id)} className="group block w-44">
      <div
        className="relative h-[312px] w-44 overflow-hidden rounded-[14px] border border-line group-hover:border-[#3a3a46]"
        style={{ background: toneFor(video.id) }}
      >
        <span className="absolute top-2.5 left-2.5">
          <Badge status={video.status} />
        </span>
        {video.duration_ms ? (
          <span className="absolute right-2.5 bottom-2.5 inline-flex h-[22px] items-center rounded-md bg-bg/70 px-2 font-mono text-[11px]">
            {formatDuration(video.duration_ms)}
          </span>
        ) : null}
      </div>
      <div className="mt-2.5 text-sm leading-snug font-medium">{title}</div>
      <div className="mt-0.5 text-xs text-label">{meta}</div>
    </a>
  )
}
