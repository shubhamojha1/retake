import type { VideoStatus } from '../lib/types.ts'

const LOOK: Record<VideoStatus, { label: string; box: string; dot: string }> = {
  succeeded: { label: 'Ready', box: 'bg-ok-bg text-ok', dot: 'bg-ok' },
  failed: { label: 'Failed', box: 'bg-warn-bg text-warn', dot: 'bg-warn' },
  running: { label: 'Running', box: 'bg-accent-bg text-accent', dot: 'bg-accent' },
  queued: { label: 'Queued', box: 'bg-raised text-muted', dot: 'bg-muted' },
}

/** A video's status as a small pill. */
export default function Badge({ status }: { status: VideoStatus }) {
  const look = LOOK[status]

  return (
    <span className={`inline-flex h-[22px] items-center gap-1.5 rounded-full px-2 text-[11px] font-medium ${look.box}`}>
      <span className={`size-1.5 rounded-full ${look.dot}`} />
      {look.label}
    </span>
  )
}
